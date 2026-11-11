# CI's image build (.github/workflows/ci.yml). Local builds go through the justfile.
# One bake builds all three flavors in parallel and builds the shared `base` stage once.

variable "CLAUDE_CODE_VERSION" {
  default = "latest"
}

# Set here, not as a Containerfile ARG: a per-commit ARG would bust the cache of
# every layer after it.
variable "REVISION" {
  default = ""
}

# Registry cache ref prefix (CI: <repo>:cache-<arch>); empty disables the cache.
variable "CACHE_PREFIX" {
  default = ""
}

function "cache_from" {
  params = [flavor]
  result = CACHE_PREFIX == "" ? [] : ["type=registry,ref=${CACHE_PREFIX}-${flavor}"]
}

# ignore-error: a failed cache push must not fail a publish.
function "cache_to" {
  params = [flavor]
  result = CACHE_PREFIX == "" ? [] : ["type=registry,ref=${CACHE_PREFIX}-${flavor},mode=max,image-manifest=true,oci-mediatypes=true,ignore-error=true"]
}

group "default" {
  targets = ["personal", "vertex", "gateway"]
}

target "_common" {
  context    = "."
  dockerfile = "Containerfile"
  args = {
    CLAUDE_CODE_VERSION = CLAUDE_CODE_VERSION
  }
  labels = REVISION == "" ? {} : {
    "org.opencontainers.image.revision" = REVISION
  }
}

target "personal" {
  inherits   = ["_common"]
  target     = "personal"
  cache-from = cache_from("personal")
  cache-to   = cache_to("personal")
}

target "vertex" {
  inherits   = ["_common"]
  target     = "vertex"
  cache-from = cache_from("vertex")
  cache-to   = cache_to("vertex")
}

target "gateway" {
  inherits   = ["_common"]
  target     = "gateway"
  cache-from = cache_from("gateway")
  cache-to   = cache_to("gateway")
}
