package flavor

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/multigl/claude-container/internal/config"
	"github.com/multigl/claude-container/internal/paths"
)

type vertex struct {
	paths          paths.Paths
	gcloudCredsDir string
}

func newVertex(p paths.Paths) vertex {
	return vertex{paths: p, gcloudCredsDir: filepath.Join(p.StateDir, "creds", "gcloud")}
}

func (v vertex) Name() string        { return "vertex" }
func (v vertex) CredDirs() []string  { return []string{v.gcloudCredsDir} }
func (v vertex) CredPaths() []string { return []string{v.gcloudCredsDir} }
func (v vertex) RunFlags() []string {
	return []string{"-v", v.gcloudCredsDir + ":/home/claude/.config/gcloud"}
}

// --no-launch-browser prints a URL to paste into the host browser, then reads the code back.
func (v vertex) AuthCommand() ([]string, string, string) {
	return []string{"gcloud", "auth", "application-default", "login", "--no-launch-browser"},
		">> running 'gcloud auth application-default login --no-launch-browser' inside container",
		">> done. credentials saved to " + v.gcloudCredsDir
}

func (v vertex) SeedConfig() string {
	return seedConfig("vertex", `# claude-vertex: model + region pins. Passed into the container as environment
# (overrides the image ENV). Confirm the exact model IDs are enabled in your
# project's Model Garden.
#
# ============================ REQUIRED: SET THIS =============================
# The GCP project that serves the models. The image bakes only a placeholder
# ('your-gcp-project'), so unless you built with --build-arg VERTEX_PROJECT_ID=,
# uncomment the line below and fill it in -- every request fails without it, and
# the container prints a loud banner at every launch until you do.
#
# Leave it COMMENTED (not empty) if the project is baked into the image: an
# empty value here would override the baked one with nothing.
# ANTHROPIC_VERTEX_PROJECT_ID = "acme-ai-prod"
# =============================================================================
#
# All US regions, for data-residency requirements: Opus 5 + Sonnet 5 aren't
# served on single regions like us-east5 -- they need global/multi-region, so
# they ride the "us" multi-region below. Haiku 4.5 -> us-east5 (also US). Drop
# these pins if your own residency rules differ.
#
# Pinning matters: unpinned on Vertex, the small/fast (background) model defaults
# to claude-sonnet-4-5, which 429s if your project can't invoke it (it powers
# session titles + web-search summarization). Pinning also restores the 1M
# context window -- append [1m] to a model ID; Sonnet 5 is always 1M (no suffix).
ANTHROPIC_MODEL = "claude-opus-5[1m]"
ANTHROPIC_DEFAULT_OPUS_MODEL = "claude-opus-5[1m]"
ANTHROPIC_DEFAULT_SONNET_MODEL = "claude-sonnet-5"
ANTHROPIC_DEFAULT_HAIKU_MODEL = "claude-haiku-4-5"
CLOUD_ML_REGION = "us"
VERTEX_REGION_CLAUDE_HAIKU_4_5 = "us-east5"
`, atlassianBlock(), context7Block())
}

func (v vertex) PrintPaths() []string {
	return []string{"CRED_GCLOUD_DIR=" + v.gcloudCredsDir}
}

func (v vertex) Doctor(cfg config.Config) []string {
	var lines []string
	if _, err := os.Stat(filepath.Join(v.gcloudCredsDir, "application_default_credentials.json")); err == nil {
		lines = append(lines, fmt.Sprintf("  ok: ADC credentials present (%s)", v.gcloudCredsDir))
	} else {
		lines = append(lines, "  MISSING ADC: run 'claude-vertex auth'")
	}
	// Only config.toml is visible here; a project baked in with --build-arg lives
	// in the image, so an empty value is "unset here", not necessarily broken.
	project := cfg.Env["ANTHROPIC_VERTEX_PROJECT_ID"]
	if doctorPlaceholderProjects[project] {
		return append(lines,
			fmt.Sprintf("  MISSING PROJECT: set ANTHROPIC_VERTEX_PROJECT_ID in [env] of %s", v.paths.HostConfig),
			"                   (ignore if the project was baked in with --build-arg VERTEX_PROJECT_ID=...)")
	}
	return append(lines, "  ok: vertex project "+project)
}

func (v vertex) LegacyVolume() string { return "claude-vertex-gcloud" }
