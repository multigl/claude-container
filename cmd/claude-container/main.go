package main

import (
	"os"

	"github.com/multigl/claude-container/internal/app"
)

func main() {
	os.Exit(app.Main(os.Args, os.Environ()))
}
