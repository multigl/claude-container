package runtime

type docker struct{}

func (docker) Name() string   { return "docker" }
func (docker) Binary() string { return "docker" }

// The launcher already passes HOST_UID/HOST_GID for the entrypoint's remap.
func (docker) RunFlags() []string { return nil }

func (docker) SSHFlags(socket string) []string { return socketMountFlags(socket) }

func (docker) Pull(image string) error { return pull("docker", "pull", image) }

func (docker) ImageLabel(image, key string) string { return inspectLabel("docker", image, key) }
