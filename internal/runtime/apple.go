package runtime

type apple struct{}

func (apple) Name() string   { return "apple" }
func (apple) Binary() string { return "container" }

// Apple's share passes host UIDs through, so it uses the same HOST_UID remap as
// docker: no userns flag and no remap-skip signal.
func (apple) RunFlags() []string { return nil }

// `--ssh` forwards the host agent and sets the in-guest socket path itself.
func (apple) SSHFlags(socket string) []string {
	if socket == "" {
		return nil
	}
	return []string{"--ssh"}
}

func (apple) Pull(image string) error { return pull("container", "image", "pull", image) }

// `image inspect` output shape isn't pinned down; report nothing.
func (apple) ImageLabel(image, key string) string { return "" }
