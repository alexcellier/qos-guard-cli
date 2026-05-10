package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// TokenBucket implements a token bucket rate limiter.
type TokenBucket struct {
	mu         sync.Mutex
	tokens     float64
	maxTokens  float64
	refillRate float64 // tokens per second
	lastRefill time.Time
}

// NewTokenBucket creates a new token bucket with the given max tokens and refill rate.
func NewTokenBucket(maxTokens, refillRate float64) *TokenBucket {
	return &TokenBucket{
		tokens:     maxTokens,
		maxTokens:  maxTokens,
		refillRate: refillRate,
		lastRefill: time.Now(),
	}
}

// Refill adds tokens based on elapsed time. Must be called with mu held.
func (tb *TokenBucket) Refill() {
	now := time.Now()
	elapsed := now.Sub(tb.lastRefill).Seconds()
	tb.tokens += elapsed * tb.refillRate
	if tb.tokens > tb.maxTokens {
		tb.tokens = tb.maxTokens
	}
	tb.lastRefill = now
}

// Allow checks if the given number of bytes can be processed immediately.
// If not, it sleeps until enough tokens are available.
// Returns the actual delay applied.
func (tb *TokenBucket) Allow(n int) (time.Duration, error) {
	tb.mu.Lock()
	defer tb.mu.Unlock()

	tb.Refill()

	if tb.tokens >= float64(n) {
		tb.tokens -= float64(n)
		return 0, nil
	}

	// Calculate how long to wait for enough tokens
	tokensNeeded := float64(n) - tb.tokens
	waitTime := tokensNeeded / tb.refillRate
	time.Sleep(time.Duration(waitTime * float64(time.Second)))

	tb.Refill()
	tb.tokens -= float64(n)
	return time.Duration(waitTime * float64(time.Second)), nil
}

// BandwidthStats tracks bandwidth usage statistics.
type BandwidthStats struct {
	mu          sync.Mutex
	totalBytes  int64
	requestCount int
	lastUpdate  time.Time
}

// NewBandwidthStats creates a new bandwidth stats tracker.
func NewBandwidthStats() *BandwidthStats {
	return &BandwidthStats{
		lastUpdate: time.Now(),
	}
}

// AddBytes adds bytes to the stats and returns current throughput.
func (bs *BandwidthStats) AddBytes(n int) (int64, float64) {
	bs.mu.Lock()
	defer bs.mu.Unlock()

	bs.totalBytes += int64(n)
	bs.requestCount++

	elapsed := time.Since(bs.lastUpdate).Seconds()
	var throughput float64
	if elapsed > 0 {
		throughput = float64(bs.totalBytes) / elapsed / 1024 / 1024 // MB/s
	}

	return bs.totalBytes, throughput
}

// Reset resets the stats counters.
func (bs *BandwidthStats) Reset() {
	bs.mu.Lock()
	defer bs.mu.Unlock()
	bs.totalBytes = 0
	bs.requestCount = 0
	bs.lastUpdate = time.Now()
}

// ParseBandwidthLimit parses a bandwidth limit string like "10mb", "500kb", "1gb".
func ParseBandwidthLimit(s string) (float64, error) {
	s = strings.ToLower(strings.TrimSpace(s))

	var multiplier float64
	switch {
	case strings.HasSuffix(s, "gb"):
		multiplier = 1000000000
		s = strings.TrimSuffix(s, "gb")
	case strings.HasSuffix(s, "mb"):
		multiplier = 1000000
		s = strings.TrimSuffix(s, "mb")
	case strings.HasSuffix(s, "kb"):
		multiplier = 1000
		s = strings.TrimSuffix(s, "kb")
	case strings.HasSuffix(s, "bps"):
		multiplier = 1
		s = strings.TrimSuffix(s, "bps")
	default:
		// Assume bytes per second if no unit
		multiplier = 1
	}

	val, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid bandwidth limit %q: %w", s, err)
	}

	return val * multiplier, nil
}

// ParseBandwidthLimitToBytes converts Mbps to bytes per second.
func ParseBandwidthLimitToBytes(s string) (float64, error) {
	bps, err := ParseBandwidthLimit(s)
	if err != nil {
		return 0, err
	}
	return bps / 8, nil // Convert bits to bytes
}

// ProxyServer is the main proxy server.
type ProxyServer struct {
	bind        string
	limit       string
	protocol    string
	verbose     bool
	pid         int
	bucket      *TokenBucket
	stats       *BandwidthStats
	logger      *log.Logger
	httpServer  *http.Server
	socksPort   int
}

// NewProxyServer creates a new ProxyServer.
func NewProxyServer(bind, limit, protocol string, verbose bool, pid int) *ProxyServer {
	bytesPerSec, err := ParseBandwidthLimitToBytes(limit)
	if err != nil {
		bytesPerSec = 1000000 // Default 1 Mbps
		log.Printf("Warning: failed to parse limit %q: %v, using default 1mb", limit, err)
	}

	// Max tokens = 1 second of bandwidth (burst capacity)
	burst := bytesPerSec

	return &ProxyServer{
		bind:    bind,
		limit:   limit,
		protocol: protocol,
		verbose: verbose,
		pid:     pid,
		bucket:  NewTokenBucket(burst, bytesPerSec),
		stats:   NewBandwidthStats(),
		logger: log.New(os.Stdout, "[qos-proxy] ", log.LstdFlags),
	}
}

// Log logs a message if verbose mode is enabled.
func (ps *ProxyServer) Log(format string, args ...interface{}) {
	if ps.verbose {
		ps.logger.Printf(format, args...)
	}
}

// LogInfo logs an info message always.
func (ps *ProxyServer) LogInfo(format string, args ...interface{}) {
	ps.logger.Printf(format, args...)
}

// LogRate logs a rate limiting event.
func (ps *ProxyServer) LogRate(bytes int, delay time.Duration) {
	if ps.verbose || delay > time.Millisecond {
		ps.logger.Printf("RATE: %d bytes, delay: %v", bytes, delay)
	}
}

// Start starts the proxy server(s).
func (ps *ProxyServer) Start() error {
	ctx := context.Background()

	// Start SOCKS5 proxy if needed
	if ps.protocol == "socks5" || ps.protocol == "all" {
		if err := ps.startSOCKS5(ctx); err != nil {
			return fmt.Errorf("failed to start SOCKS5 proxy: %w", err)
		}
	}

	// Start HTTP proxy
	if ps.protocol == "http" || ps.protocol == "all" {
		if err := ps.startHTTP(); err != nil {
			return fmt.Errorf("failed to start HTTP proxy: %w", err)
		}
	}

	// Print startup info
	addr := ps.bind
	if ps.protocol == "socks5" && ps.socksPort > 0 {
		addr = fmt.Sprintf("SOCKS5:127.0.0.1:%d", ps.socksPort)
	} else if ps.protocol == "http" {
		addr = fmt.Sprintf("HTTP:%s", ps.bind)
	} else {
		addr = fmt.Sprintf("HTTP:%s + SOCKS5:127.0.0.1:%d", ps.bind, ps.socksPort)
	}

	ps.LogInfo("qos-proxy started on %s", addr)
	ps.LogInfo("Bandwidth limit: %s (%.0f bytes/sec)", ps.limit, ps.bucket.refillRate)
	if ps.pid > 0 {
		ps.LogInfo("Target PID: %d", ps.pid)
	}
	ps.LogInfo("Protocol: %s", ps.protocol)
	ps.LogInfo("Verbose: %v", ps.verbose)

	return nil
}

// startHTTP starts the HTTP proxy server.
func (ps *ProxyServer) startHTTP() error {
	// HTTP proxy handler
	proxyHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		startTime := time.Now()

		// Connect to target
		targetHost := r.URL.Host
		if targetHost == "" {
			targetHost = r.Host
		}

		// Parse host:port
		host, port, err := net.SplitHostPort(targetHost)
		if err != nil {
			host = targetHost
			port = "80"
			if r.URL.Scheme == "https" {
				port = "443"
			}
		}

		// Connect to target
		conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, port), 10*time.Second)
		if err != nil {
			http.Error(w, fmt.Sprintf("Failed to connect: %v", err), http.StatusBadGateway)
			return
		}
		defer conn.Close()

		// Read response
		respReader := bufio.NewReader(conn)
		resp, err := http.ReadResponse(respReader, r)
		if err != nil {
			http.Error(w, fmt.Sprintf("Failed to read response: %v", err), http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()

		// Track response size
		respSize := 0
		respBuf := make([]byte, 32*1024)
		for {
			n, err := resp.Body.Read(respBuf)
			respSize += n
			if err == io.EOF {
				break
			}
			if err != nil {
				ps.logger.Printf("Error reading response body: %v", err)
				break
			}
		}

		// Apply rate limiting
		delay, err := ps.bucket.Allow(respSize)
		if err != nil {
			ps.logger.Printf("Rate limiter error: %v", err)
		}
		ps.LogRate(respSize, delay)

		// Update stats
		totalBytes, throughput := ps.stats.AddBytes(respSize)

		// Log connection
		ps.LogInfo("HTTP %s %s -> %s (%d bytes, throughput: %.2f MB/s)",
			r.Method, r.URL.Path, targetHost, respSize, throughput)

		if ps.verbose {
			elapsed := time.Since(startTime).Milliseconds()
			ps.LogInfo("Total request time: %dms, cumulative bytes: %d", elapsed, totalBytes)
		}

		// Write response headers
		for key, values := range resp.Header {
			for _, value := range values {
				w.Header().Add(key, value)
			}
		}
		w.WriteHeader(resp.StatusCode)

		// Write response body (already read above, skip)
	})

	// CONNECT handler for HTTPS
	connectHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		targetHost := r.Host
		conn, err := net.DialTimeout("tcp", targetHost, 10*time.Second)
		if err != nil {
			http.Error(w, fmt.Sprintf("Failed to connect: %v", err), http.StatusBadGateway)
			return
		}

		// Send 200 OK
		w.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\n"))

		// Apply rate limiting for the connection
		go ps.rateLimitConnection(conn)

		// Hijack connection
		hj, ok := w.(http.Hijacker)
		if !ok {
			conn.Close()
			http.Error(w, "Server doesn't support hijacking", http.StatusInternalServerError)
			return
		}

		clientConn, _, err := hj.Hijack()
		if err != nil {
			conn.Close()
			http.Error(w, "Hijacking failed", http.StatusInternalServerError)
			return
		}

		// Forward data both ways
		go ps.forward(clientConn, conn)
		ps.forward(conn, clientConn)
	})

	// Handle both proxy requests and CONNECT
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "CONNECT" {
			connectHandler.ServeHTTP(w, r)
			return
		}
		proxyHandler.ServeHTTP(w, r)
	})

	ps.httpServer = &http.Server{
		Addr:    ps.bind,
		Handler: handler,
	}

	// Start HTTP server in goroutine
	go func() {
		ps.LogInfo("HTTP proxy listening on %s", ps.bind)
		if err := ps.httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			ps.logger.Printf("HTTP server error: %v", err)
		}
	}()

	return nil
}

// startSOCKS5 starts the SOCKS5 proxy server.
func (ps *ProxyServer) startSOCKS5(ctx context.Context) error {
	// Use txthinking/socks package
	socksAddr := "127.0.0.1:0" // Let OS assign a port
	listener, err := net.Listen("tcp", socksAddr)
	if err != nil {
		return fmt.Errorf("failed to create SOCKS5 listener: %w", err)
	}

	ps.socksPort = listener.Addr().(*net.TCPAddr).Port

	// Wrap listener to apply rate limiting
	wrappedListener := &rateLimitedListener{
		Listener: listener,
		server:   ps,
	}

	ps.LogInfo("SOCKS5 proxy listening on %s", listener.Addr())

	go func() {
		for {
			conn, err := wrappedListener.Accept()
			if err != nil {
				ps.logger.Printf("SOCKS5 accept error: %v", err)
				return
			}
			go ps.handleSOCKS5Connection(conn)
		}
	}()

	return nil
}

// handleSOCKS5Connection handles a single SOCKS5 connection.
func (ps *ProxyServer) handleSOCKS5Connection(conn net.Conn) {
	defer conn.Close()

	// Read SOCKS5 request
	reader := bufio.NewReader(conn)

	// Actually read the length byte first
	buf := make([]byte, 1)
	if _, err := reader.Read(buf); err != nil {
		ps.logger.Printf("SOCKS5 read error: %v", err)
		return
	}
	methodLen := int(buf[0])

	if methodLen == 0 {
		return
	}

	methodBuf := make([]byte, methodLen)
	if _, err := io.ReadFull(reader, methodBuf); err != nil {
		ps.logger.Printf("SOCKS5 method read error: %v", err)
		return
	}

	// Send no-auth response
	response := []byte{0x05, 0x00}
	conn.Write(response)

	// Read SOCKS5 request
	cmdBuf := make([]byte, 1)
	if _, err := reader.Read(cmdBuf); err != nil {
		return
	}
	// Read address type
	if _, err := reader.Read(cmdBuf); err != nil {
		return
	}
	addrType := cmdBuf[0]

	// Read address
	var addrBuf []byte
	switch addrType {
	case 0x01: // IPv4
		addrBuf = make([]byte, 4)
		io.ReadFull(reader, addrBuf)
		addr := net.IP(addrBuf).String()
		// Read port
		portBuf := make([]byte, 2)
		io.ReadFull(reader, portBuf)
		port := int(portBuf[0])<<8 | int(portBuf[1])
		ps.connectAndForward(conn, fmt.Sprintf("%s:%d", addr, port))
	case 0x03: // Domain name
		if _, err := reader.Read(cmdBuf); err != nil {
			return
		}
		domainLen := int(cmdBuf[0])
		addrBuf = make([]byte, domainLen)
		io.ReadFull(reader, addrBuf)
		domain := string(addrBuf)
		// Read port
		portBuf := make([]byte, 2)
		io.ReadFull(reader, portBuf)
		port := int(portBuf[0])<<8 | int(portBuf[1])
		ps.connectAndForward(conn, fmt.Sprintf("%s:%d", domain, port))
	case 0x04: // IPv6
		addrBuf = make([]byte, 16)
		io.ReadFull(reader, addrBuf)
		addr := net.IP(addrBuf).String()
		portBuf := make([]byte, 2)
		io.ReadFull(reader, portBuf)
		port := int(portBuf[0])<<8 | int(portBuf[1])
		ps.connectAndForward(conn, fmt.Sprintf("[%s]:%d", addr, port))
	default:
		ps.sendSOCKS5Response(conn, 0x04, "")
	}
}

// connectAndForward connects to target and forwards data.
func (ps *ProxyServer) connectAndForward(clientConn net.Conn, targetAddr string) {
	serverConn, err := net.DialTimeout("tcp", targetAddr, 10*time.Second)
	if err != nil {
		ps.sendSOCKS5Response(clientConn, 0x04, "")
		return
	}
	defer serverConn.Close()

	// Send success response
	ps.sendSOCKS5Response(clientConn, 0x00, "")

	// Apply rate limiting
	go ps.rateLimitConnection(serverConn)

	// Forward data both ways
	ps.forward(clientConn, serverConn)
	ps.forward(serverConn, clientConn)
}

// sendSOCKS5Response sends a SOCKS5 response.
func (ps *ProxyServer) sendSOCKS5Response(conn net.Conn, reply byte, addr string) {
	response := []byte{0x05, reply, 0x00, 0x01}
	if addr != "" {
		host, portStr, _ := net.SplitHostPort(addr)
		if ip := net.ParseIP(host); ip != nil {
			if ip.To4() != nil {
				response = append(response, 0x01) // IPv4
				response = append(response, ip.To4()...)
			} else {
				response = append(response, 0x04) // IPv6
				response = append(response, ip.To16()...)
			}
		} else {
			response = append(response, 0x03) // Domain
			response = append(response, byte(len(host)))
			response = append(response, []byte(host)...)
		}
		port, _ := strconv.Atoi(portStr)
		response = append(response, byte(port>>8), byte(port))
	}
	conn.Write(response)
}

// rateLimitConnection wraps a connection with rate limiting.
func (ps *ProxyServer) rateLimitConnection(conn net.Conn) {
	// Create a wrapped reader
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := conn.Read(buf)
			if err != nil {
				return
			}

			delay, _ := ps.bucket.Allow(n)
			ps.LogRate(n, delay)

			totalBytes, throughput := ps.stats.AddBytes(n)
			ps.LogInfo("SOCKS5 data: %d bytes (throughput: %.2f MB/s, total: %d bytes)",
				n, throughput, totalBytes)
		}
	}()
}

// forward forwards data from src to dst.
func (ps *ProxyServer) forward(src, dst net.Conn) {
	buf := make([]byte, 32*1024)
	for {
		src.SetReadDeadline(time.Now().Add(30 * time.Second))
		n, err := src.Read(buf)
		if err != nil {
			return
		}

		delay, _ := ps.bucket.Allow(n)
		ps.LogRate(n, delay)

		totalBytes, throughput := ps.stats.AddBytes(n)
		ps.LogInfo("Forward: %d bytes (throughput: %.2f MB/s, total: %d bytes)",
			n, throughput, totalBytes)

		dst.SetWriteDeadline(time.Now().Add(10 * time.Second))
		_, err = dst.Write(buf[:n])
		if err != nil {
			return
		}
	}
}

// rateLimitedListener is a net.Listener that applies rate limiting.
type rateLimitedListener struct {
	net.Listener
	server *ProxyServer
}

func (rl *rateLimitedListener) Accept() (net.Conn, error) {
	conn, err := rl.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return &rateLimitedConn{
		Conn: conn,
		server: rl.server,
	}, nil
}

// rateLimitedConn wraps a net.Conn with rate limiting.
type rateLimitedConn struct {
	net.Conn
	server *ProxyServer
	buf    []byte
	offset int
}

func (rc *rateLimitedConn) Read(p []byte) (int, error) {
	// Read from underlying connection
	n, err := rc.Conn.Read(p)
	if n > 0 {
		delay, _ := rc.server.bucket.Allow(n)
		rc.server.LogRate(n, delay)
		totalBytes, throughput := rc.server.stats.AddBytes(n)
		rc.server.LogInfo("SOCKS5 data: %d bytes (throughput: %.2f MB/s, total: %d bytes)",
			n, throughput, totalBytes)
	}
	return n, err
}

// Stop gracefully shuts down the proxy server.
func (ps *ProxyServer) Stop(ctx context.Context) error {
	if ps.httpServer != nil {
		return ps.httpServer.Shutdown(ctx)
	}
	return nil
}

func main() {
	// CLI flags
	bind := flag.String("b", "127.0.0.1:0", "Address to bind to (default: 127.0.0.1:0)")
	bindLong := flag.String("bind", "127.0.0.1:0", "Address to bind to (default: 127.0.0.1:0)")
	limit := flag.String("l", "10mb", "Bandwidth limit (e.g., '10mb', '500kb', '1gb')")
	limitLong := flag.String("limit", "10mb", "Bandwidth limit (e.g., '10mb', '500kb', '1gb')")
	protocol := flag.String("p", "all", "Protocol mode: 'http', 'socks5', or 'all'")
	protocolLong := flag.String("protocol", "all", "Protocol mode: 'http', 'socks5', or 'all'")
	verbose := flag.Bool("v", false, "Verbose logging")
	verboseLong := flag.Bool("verbose", false, "Verbose logging")
	pid := flag.Int("pid", 0, "Target PID for logging/context")

	flag.Parse()

	// Use long or short flag values
	b := *bind
	if *bindLong != "127.0.0.1:0" {
		b = *bindLong
	}

	l := *limit
	if *limitLong != "10mb" {
		l = *limitLong
	}

	p := *protocol
	if *protocolLong != "all" {
		p = *protocolLong
	}

	v := *verbose
	if *verboseLong {
		v = true
	}

	// Validate protocol
	switch p {
	case "http", "socks5", "all":
		// Valid
	default:
		fmt.Fprintf(os.Stderr, "Invalid protocol %q. Must be 'http', 'socks5', or 'all'\n", p)
		os.Exit(1)
	}

	// Validate limit
	if _, err := ParseBandwidthLimitToBytes(l); err != nil {
		fmt.Fprintf(os.Stderr, "Invalid bandwidth limit %q: %v\n", l, err)
		os.Exit(1)
	}

	// Create proxy server
	server := NewProxyServer(b, l, p, v, *pid)

	// Start server
	if err := server.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to start proxy: %v\n", err)
		os.Exit(1)
	}

	// Wait for signal
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGTERM, syscall.SIGINT)
	sig := <-sigChan

	fmt.Fprintf(os.Stderr, "\nReceived signal %v, shutting down...\n", sig)

	// Graceful shutdown
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := server.Stop(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "Error during shutdown: %v\n", err)
		os.Exit(1)
	}

	fmt.Fprintln(os.Stderr, "qos-proxy stopped")
}
