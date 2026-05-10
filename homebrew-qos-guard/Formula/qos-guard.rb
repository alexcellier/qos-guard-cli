class QosGuard < Formula
  desc "CLI tool for per-process bandwidth limiting using proxy-based QoS"
  homepage "https://github.com/nicely-deep/CLI-QoS"
  url "https://github.com/nicely-deep/CLI-QoS.git",
      :tag => "v1.0.0",
      :revision => "a1b2c3d4e5f6"  # Update with actual commit SHA on release
  
  license "MIT"
  
  depends_on :macos
  
  depends_on "go" => :build
  
  def install
    # Install qos-guard shell script
    bin.install "qos-guard"
    
    # Build qos-proxy from Go source
    cd "qos-proxy" do
      system "go", "build", "-ldflags", "-s -w", "-o", "../qos-proxy"
    end
    bin.install "qos-proxy"
  end
  
  def test
    # Verify qos-guard version output
    assert_match "qos-guard v", shell_output("#{bin}/qos-guard --version")
    
    # Verify qos-proxy is installed
    assert_match "qos-proxy", shell_output("#{bin}/qos-proxy --help 2>&1")
  end
end
