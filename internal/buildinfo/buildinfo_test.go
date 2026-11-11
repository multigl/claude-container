package buildinfo

import "testing"

func TestPinnedImage(t *testing.T) {
	tests := []struct {
		name        string
		version     string
		imageSuffix string
		expected    string
	}{
		{"dev build", "dev", "", "ghcr.io/multigl/claude-container:personal-latest"},
		{"release build", "v2.3.1-abc1234", "2.3.1-abc1234", "ghcr.io/multigl/claude-container:personal-2.3.1-abc1234"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			originalVersion, originalSuffix := Version, ImageSuffix
			t.Cleanup(func() { Version, ImageSuffix = originalVersion, originalSuffix })
			Version, ImageSuffix = test.version, test.imageSuffix
			if actual := PinnedImage("personal"); actual != test.expected {
				t.Errorf("got %q, want %q", actual, test.expected)
			}
		})
	}
}
