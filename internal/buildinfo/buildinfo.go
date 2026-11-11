package buildinfo

// Stamped at build time via -ldflags -X.
var (
	Version     = "dev"
	ImageRepo   = "ghcr.io/multigl/claude-container"
	ImageSuffix = ""
)

// PinnedImage returns the image this build was released with, or the
// floating -latest tag for unstamped dev builds.
func PinnedImage(flavor string) string {
	tag := flavor + "-latest"
	if Version != "dev" && ImageSuffix != "" {
		tag = flavor + "-" + ImageSuffix
	}
	return ImageRepo + ":" + tag
}
