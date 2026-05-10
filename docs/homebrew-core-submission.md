# Submitting qos-guard to homebrew-core

A comprehensive guide for submitting the [qos-guard](../README.md) Homebrew formula to the official [homebrew-core](https://github.com/Homebrew/homebrew-core) repository.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Formula Requirements](#formula-requirements)
3. [Formula Modifications Needed](#formula-modifications-needed)
4. [Submission Process](#submission-process)
5. [Common Rejection Reasons](#common-rejection-reasons)
6. [Alternative: Keep Custom Tap](#alternative-keep-custom-tap)

---

## Prerequisites

Before submitting, ensure you have the following:

### GitHub Account & Repository

- [ ] A [GitHub account](https://github.com/signup)
- [ ] The qos-guard CLI repository is public (homebrew-core reviewers need access to source code)
- [ ] GitHub Releases are configured (via `.github/workflows/release.yml`)
- [ ] At least one tagged release exists (e.g., `v1.0.0`)

### Local Tools

- [ ] **Homebrew** installed (`brew --version`)
- [ ] **Go** installed for local formula testing (`go version`, >= 1.21)
- [ ] **git** configured with your GitHub credentials
- [ ] **gh CLI** installed for PR creation (`gh --version`)

### Formula Testing

- [ ] `brew install --build-from-source .` works from the Formula directory
- [ ] `brew audit --strict qos-guard` passes with no errors
- [ ] `brew test qos-guard` passes

---

## Formula Requirements

homebrew-core has strict requirements that differ from a custom tap. Understanding these upfront prevents wasted effort.

### Source-Based Formula (Not Bottle-Only)

homebrew-core **requires** source-based formulas for Go projects. This means:

- The formula must fetch source code from a git tag (not a pre-built binary)
- Cross-compilation happens during `brew install` via the `go_build` block
- Bottles (pre-compiled binaries) may be provided but are **optional**

```ruby
# CORRECT: Source-based formula
url "https://github.com/alexcellier/qos-guard-cli.git",
    :tag => "v1.0.0"

def install
  system "go", "install", "./..."
end

# WRONG: Bottle-only formula (will be rejected)
class QosGuard < Formula
  bottle do
    sha256 cellar: ":any_skip_relocation", arm64_monterey: "abc123"
    sha256 cellar: ":any_skip_relocation", catalina: "def456"
  end
end
```

### Proper Versioning with `url`/`tag`/`sha256`

homebrew-core requires:

| Field | Purpose | Example |
|-------|---------|---------|
| `url` | Source repository URL | `https://github.com/alexcellier/qos-guard-cli.git` |
| `:tag` | Git tag for the version | `v1.0.0` |
| `:revision` | Commit SHA (optional, for non-tagged commits) | `abc123def456` |

For Go modules, you may also need `:submodules` if the project uses Go modules with external dependencies.

### `go_build` Block (Modern Go Formula Pattern)

Homebrew now recommends the `go_build` block instead of manual `go install`:

```ruby
def install
  # Set version ldflags
  version_ldflags = "-s -w -X main.Version=#{version}"

  # Build for the target platform
  system "go", "build", version_ldflags, "-o", "qos-proxy", "./qos-proxy"

  # Install the shell script
  bin.install "qos-guard"
end
```

**Note:** The newer Homebrew Go formula pattern uses `go_resource` or `go install` with `ENV.deparallelize`:

```ruby
def install
  # Use Go's module-aware build
  system "go", "mod", "download"
  system "go", "build", "-ldflags", "-s -w", "-o", "qos-proxy", "./qos-proxy"
  bin.install "qos-guard"
end
```

### License Requirements

- The repository **must** have a valid license file (`LICENSE` or `LICENSE.md`)
- The formula `license` field must match the actual license
- For MIT: `license "MIT"`

### Documentation Requirements

homebrew-core expects:

- A `desc` field (short description, under 80 characters)
- A `homepage` field pointing to the repository
- The repository should have a `README.md` with installation instructions

---

## Formula Modifications Needed

The current formula at [`Formula/qos-guard.rb`](../Formula/qos-guard.rb) needs the following changes for homebrew-core compliance.

### 1. Convert to Source-Based Formula

**Current formula uses git URL with tag** — this is acceptable but needs revision SHA for stability:

```ruby
# Current (acceptable for custom tap):
url "https://github.com/alexcellier/qos-guard-cli.git",
    :tag => "v1.0.0",
    :revision => "eb067f58c291f2214b0c6b18807ed72f5547b1b6"
```

**For homebrew-core**, use the standard Homebrew Go formula pattern:

```ruby
class QosGuard < Formula
  desc "Per-process bandwidth limiting CLI for macOS using proxy-based QoS"
  homepage "https://github.com/alexcellier/qos-guard-cli"

  url "https://github.com/alexcellier/qos-guard-cli.git",
      :tag => "v1.0.0"

  license "MIT"

  depends_on :macos

  def install
    # Install the bash wrapper script
    bin.install "qos-guard"

    # Build qos-proxy from Go source
    cd "qos-proxy" do
      system "go", "build", "-ldflags", "-s -w", "-o", "../qos-proxy"
    end
    bin.install "qos-proxy"
  end

  test do
    # Verify qos-guard version output
    assert_match "qos-guard v", shell_output("#{bin}/qos-guard --version")

    # Verify qos-proxy is installed
    assert_match "qos-proxy", shell_output("#{bin}/qos-proxy --help 2>&1")
  end
end
```

### 2. Update URL Template for Versioned Releases

When a new version is released, the formula needs:

```ruby
# Update the tag to the new version:
:url => "https://github.com/alexcellier/qos-guard-cli.git",
     :tag => "v1.1.0"   # <-- Update this

# Update the revision to the commit SHA of the tag:
:revision => "a1b2c3d4e5f6789012345678901234567890abcd"  # <-- Update this
```

**To get the revision SHA:**

```bash
git ls-remote https://github.com/alexcellier/qos-guard-cli.git refs/tags/v1.1.0
# Output: a1b2c3d4e5f6789012345678901234567890abcd	refs/tags/v1.1.0
```

### 3. Add SHA256 Hashes (If Providing Bottles)

If you provide pre-compiled bottles, add SHA256 hashes:

```ruby
bottle do
  sha256 cellar: ":any_skip_relocation", arm64_sequoia: "sha256_here"
  sha256 cellar: ":any_skip_relocation", arm64_sonoma: "sha256_here"
  sha256 cellar: ":any_skip_relocation", x86_64_sequoia: "sha256_here"
  sha256 cellar: ":any_skip_relocation", x86_64_sonoma: "sha256_here"
end
```

**To generate bottle SHA256:**

```bash
brew bottle --json qos-guard.rb
# Or manually:
shasum -a 256 qos-guard-cli-1.0.0.monterey.bottle.tar.gz
```

### 4. Recommended: Add `go_resource` Pattern (Modern Approach)

For Go projects, Homebrew recommends using `go_resource` for dependencies and `go_build` for the main build:

```ruby
class QosGuard < Formula
  desc "Per-process bandwidth limiting CLI for macOS using proxy-based QoS"
  homepage "https://github.com/alexcellier/qos-guard-cli"
  url "https://github.com/alexcellier/qos-guard-cli.git",
      :tag => "v1.0.0"

  license "MIT"

  depends_on :macos

  def install
    # Build qos-proxy
    cd "qos-proxy" do
      system "go", "build", "-ldflags", "-s -w", "-o", bin / "qos-proxy"
    end

    # Install qos-guard shell script
    bin.install "qos-guard"
  end

  test do
    assert_match "qos-guard v", shell_output("#{bin}/qos-guard --version")
    assert_match "qos-proxy", shell_output("#{bin}/qos-proxy --help 2>&1")
  end
end
```

---

## Submission Process

### Step 1: Fork homebrew-core

```bash
# Fork the repository on GitHub
gh repo fork Homebrew/homebrew-core --clone

# Navigate to the fork
cd homebrew-core
```

### Step 2: Create a Branch

```bash
git checkout -b qos-guard-new
```

### Step 3: Add the Formula

Create or update the formula file:

```bash
# Create the formula file in the repository
code Formula/qos-guard-cli.rb
```

**Recommended formula file name:** `qos-guard-cli.rb` (to avoid conflicts with existing `qos-guard` formulas)

### Step 4: Run Local Audits

```bash
# Strict audit (required)
brew audit --strict Formula/qos-guard-cli.rb

# Install from source (test the formula)
brew install --build-from-source Formula/qos-guard-cli.rb

# Test the installed formula
brew test qos-guard-cli
```

### Step 5: Commit and Push

```bash
git add Formula/qos-guard-cli.rb
git commit -m "qos-guard-cli: create initial formula at 1.0.0"
git push origin qos-guard-new
```

### Step 6: Create the PR

```bash
gh pr create \
  --base master \
  --head qos-guard-new \
  --title "qos-guard-cli: create initial formula at 1.0.0" \
  --body "## What does this do?

qos-guard is a per-process bandwidth limiting CLI tool for macOS.
It uses a proxy-based approach to apply bandwidth limits to any command.

## Testing

- [x] Ran `brew audit --strict qos-guard-cli` - passed
- [x] Ran `brew install --build-from-source` - passed
- [x] Ran `brew test qos-guard-cli` - passed

## Formula

See [Formula/qos-guard-cli.rb](Formula/qos-guard-cli.rb) for details."
```

### Step 7: Respond to Review Feedback

Homebrew maintainers may request changes. Common requests:

- Formula style adjustments
- Test block improvements
- Description wording changes
- Version bump requirements

Address each comment and push updates to the same branch.

---

## Common Rejection Reasons

### 1. "Formula does not build from source"

**Cause:** The formula relies on pre-built bottles or external binary downloads.

**Fix:** Ensure the formula builds everything from source using `go build`:

```ruby
def install
  cd "qos-proxy" do
    system "go", "build", "-ldflags", "-s -w", "-o", bin / "qos-proxy"
  end
  bin.install "qos-guard"
end
```

### 2. "Missing test block"

**Cause:** No `test do` block to verify the installation.

**Fix:** Add a meaningful test:

```ruby
test do
  assert_match "qos-guard v", shell_output("#{bin}/qos-guard --version")
  assert_predicate share / "doc", :directory?
end
```

### 3. "Description too long"

**Cause:** `desc` field exceeds 80 characters.

**Fix:** Shorten the description:

```ruby
# Too long (88 chars):
desc "Per-process bandwidth limiting CLI for macOS using proxy-based QoS"

# Good (72 chars):
desc "Per-process bandwidth limiting CLI for macOS"
```

### 4. "License file not found"

**Cause:** The repository lacks a `LICENSE` file or the formula's `license` field doesn't match.

**Fix:** Ensure `LICENSE` exists in the repository root and matches:

```ruby
license "MIT"  # Must match the LICENSE file
```

### 5. "URL does not match tag"

**Cause:** The `url` and `tag` parameters are inconsistent.

**Fix:** Verify the tag exists:

```bash
git ls-remote --tags origin | grep v1.0.0
# Should show the tag commit
```

### 6. "Shallow clone not allowed"

**Cause:** Using `:shallow => true` or fetching from a non-tagged commit.

**Fix:** Always use full tag references:

```ruby
url "https://github.com/alexcellier/qos-guard-cli.git",
    :tag => "v1.0.0"  # Full tag, not a branch name
```

### 7. "Formula uses deprecated patterns"

**Cause:** Using outdated Homebrew DSL patterns.

**Fix:** Follow the [Homebrew Go Formula Cookbook](https://github.com/Homebrew/homebrew-core/blob/master/docs/Go.md):

```ruby
# Use bin.install instead of install:
bin.install "qos-guard"

# Use shell_output instead of system output capture:
assert_match "qos-guard v", shell_output("#{bin}/qos-guard --version")
```

### 8. "Duplicate formula name"

**Cause:** A formula with the same name already exists in homebrew-core.

**Fix:** Choose a unique name. Check first:

```bash
brew search qos-guard
# If something exists, consider: qos-guard-cli, qosguard, qos-cli
```

---

## Alternative: Keep Custom Tap

### When to Keep the Custom Tap

Keep your custom tap (`homebrew-qos-guard`) if:

- Your formula uses macOS-specific features not suitable for homebrew-core
- You want faster iteration without waiting for homebrew-core review
- The tool is experimental or frequently changing
- You need dependencies not available in homebrew-core

### Maintaining the Custom Tap

Your current tap at [`homebrew-qos-guard/Formula/qos-guard.rb`](../homebrew-qos-guard/Formula/qos-guard.rb) should be updated to match the source-based pattern:

```ruby
class QosGuard < Formula
  desc "Per-process bandwidth limiting CLI for macOS using proxy-based QoS"
  homepage "https://github.com/alexcellier/qos-guard-cli"
  url "https://github.com/alexcellier/qos-guard-cli.git",
      :tag => "v1.0.0"

  license "MIT"

  depends_on :macos

  def install
    cd "qos-proxy" do
      system "go", "build", "-ldflags", "-s -w", "-o", bin / "qos-proxy"
    end
    bin.install "qos-guard"
  end

  test do
    assert_match "qos-guard v", shell_output("#{bin}/qos-guard --version")
  end
end
```

Users can install from your tap:

```bash
brew tap alexcellier/homebrew-qos-guard
brew install qos-guard
```

### Hybrid Approach: Tap + homebrew-core Submission

You can maintain **both**:

1. **Custom tap** for early access and rapid iteration
2. **homebrew-core submission** for wider distribution

When homebrew-core approves, users get:

```bash
brew install qos-guard-cli  # From homebrew-core (official)
```

While tap users continue to use:

```bash
brew tap alexcellier/homebrew-qos-guard
brew install qos-guard  # From custom tap
```

### Migrating from Tap to homebrew-core

Once homebrew-core approves:

1. Announce the tap deprecation in your README
2. Update tap users to the new formula name:

```bash
# Old (tap)
brew tap alexcellier/homebrew-qos-guard
brew install qos-guard

# New (homebrew-core)
brew install qos-guard-cli
```

3. Keep the tap repository as an archive or redirect to the homebrew-core installation

---

## Appendix: Formula File Checklist

Before submitting, verify:

- [ ] `desc` is under 80 characters
- [ ] `homepage` points to the public repository
- [ ] `url` uses a valid git tag
- [ ] `license` matches the repository LICENSE file
- [ ] `depends_on :macos` is present (if macOS-only)
- [ ] `depends_on "go" => :build` is present (if needed)
- [ ] `install` block builds from source
- [ ] `test` block verifies installation
- [ ] `brew audit --strict` passes
- [ ] `brew install --build-from-source` works
- [ ] No deprecated DSL patterns used

---

## References

- [Homebrew Formula Cookbook](https://docs.brew.sh/Formula-Cookbook)
- [Homebrew Go Formula Guidelines](https://github.com/Homebrew/homebrew-core/blob/master/docs/Go.md)
- [homebrew-core Contribution Guidelines](https://github.com/Homebrew/homebrew-core/blob/master/CONTRIBUTING.md)
- [homebrew-core Formula Style](https://github.com/Homebrew/homebrew-core/blob/master/CONTRIBUTING.md#formula-style)
