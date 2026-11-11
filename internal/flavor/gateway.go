package flavor

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/multigl/claude-container/internal/config"
	"github.com/multigl/claude-container/internal/paths"
)

type gateway struct {
	paths        paths.Paths
	oktaCredsDir string
}

func newGateway(p paths.Paths) gateway {
	return gateway{paths: p, oktaCredsDir: filepath.Join(p.StateDir, "creds", "okta")}
}

func (g gateway) Name() string        { return "gateway" }
func (g gateway) CredDirs() []string  { return []string{g.oktaCredsDir} }
func (g gateway) CredPaths() []string { return []string{g.oktaCredsDir} }
func (g gateway) RunFlags() []string {
	return []string{"-v", g.oktaCredsDir + ":/home/claude/.local/share/litellm"}
}

// The helper prints a verification URL to stderr; --login-only fills the token
// cache without emitting a token.
func (g gateway) AuthCommand() ([]string, string, string) {
	return []string{"/opt/claude/api-key-helper", "--login-only"},
		">> Okta device login inside container (approve in your browser)",
		">> done. token cache saved to " + g.oktaCredsDir
}

func (g gateway) SeedConfig() string {
	return seedConfig("gateway", `# claude-gateway: the baked Okta apiKeyHelper reads these to mint an id_token.
# OKTA_ISSUER = your Okta Org server (no /oauth2/<id>); OKTA_CLIENT_ID = the
# Native app client_id (must equal LiteLLM's JWT_AUDIENCE). Run `+"`claude-gateway auth`"+`
# once to complete the browser device login. Passed into the container as environment.
OKTA_ISSUER = "https://YOUR-ORG.okta.com"
OKTA_CLIENT_ID = ""
CLAUDE_CODE_API_KEY_HELPER_TTL_MS = "300000"
# ANTHROPIC_BASE_URL = "https://litellm.internal.example.com"   # gateway endpoint override
`, atlassianBlock(), context7Block())
}

func (g gateway) PrintPaths() []string {
	return []string{"CRED_OKTA_DIR=" + g.oktaCredsDir}
}

func (g gateway) Doctor(cfg config.Config) []string {
	var lines []string
	if entries, err := os.ReadDir(g.oktaCredsDir); err == nil && len(entries) > 0 {
		lines = append(lines, fmt.Sprintf("  ok: Okta token cache present (%s)", g.oktaCredsDir))
	} else {
		lines = append(lines, "  MISSING: run 'claude-gateway auth'")
	}
	if cfg.Env["OKTA_CLIENT_ID"] != "" {
		return append(lines, fmt.Sprintf("  ok: OKTA_CLIENT_ID set in %s", g.paths.HostConfig))
	}
	return append(lines, fmt.Sprintf("  MISSING: set OKTA_CLIENT_ID in [env] of %s", g.paths.HostConfig))
}

func (g gateway) LegacyVolume() string { return "claude-gateway-okta" }
