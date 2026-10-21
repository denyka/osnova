// osnova: the one build definition, local and CI (SPEC 3.3, 6.5).
// Every BASE_* variable defaults to the bare tag so the file parses alone;
// `make build` and the pipeline override each with <tag>@sha256:<digest>
// from tools/resolve_bases.sh through the environment.

variable "REGISTRY" {
  default = "ghcr.io/denyka/osnova"
}

variable "TAG" {
  default = "latest"
}

// Empty means the host's own platform: builds are native, never emulated
// (SPEC 3.5). CI sets one platform per runner.
variable "PLATFORMS" {
  default = ""
}

// Set by the pipeline (SPEC 6.5); "dev" marks a local build.
variable "REVISION" {
  default = "dev"
}

variable "CREATED" {
  default = "1970-01-01T00:00:00Z"
}

variable "VERSION" {
  default = "dev"
}

variable "BASE_ALMALINUX9" {
  default = "almalinux:9-minimal"
}

variable "BASE_ALMALINUX10" {
  default = "almalinux:10-minimal"
}

variable "BASE_DEBIAN12" {
  default = "debian:12-slim"
}

variable "BASE_DEBIAN13" {
  default = "debian:13-slim"
}

variable "BASE_UBUNTU2404" {
  default = "ubuntu:24.04"
}

variable "BASE_UBUNTU2604" {
  default = "ubuntu:26.04"
}

// base_name and base_digest split "<tag>@sha256:<digest>"; for a bare tag
// the digest is "unresolved", which a release never produces.
function "base_name" {
  params = [ref]
  result = split("@", ref)[0]
}

function "base_digest" {
  params = [ref]
  result = length(split("@", ref)) > 1 ? split("@", ref)[1] : "unresolved"
}

function "labels" {
  params = [name, ref]
  result = {
    "org.opencontainers.image.title"       = name
    "org.opencontainers.image.source"      = "https://github.com/denyka/osnova"
    "org.opencontainers.image.url"         = "https://github.com/denyka/osnova/pkgs/container/osnova%2F${name}"
    "org.opencontainers.image.revision"    = REVISION
    "org.opencontainers.image.created"     = CREATED
    "org.opencontainers.image.version"     = VERSION
    "org.opencontainers.image.base.name"   = base_name(ref)
    "org.opencontainers.image.base.digest" = base_digest(ref)
  }
}

target "_common" {
  platforms = PLATFORMS == "" ? [] : [PLATFORMS]
}

// The context is the family directory, which holds only the Dockerfile, so
// the root .dockerignore does not apply and no copy of it is needed.
target "_el" {
  inherits   = ["_common"]
  context    = "images/el"
  dockerfile = "Dockerfile"
}

target "_deb" {
  inherits   = ["_common"]
  context    = "images/deb"
  dockerfile = "Dockerfile"
}

target "almalinux9" {
  inherits = ["_el"]
  args     = { BASE_IMAGE = BASE_ALMALINUX9 }
  tags     = ["${REGISTRY}/almalinux9:${TAG}"]
  labels   = labels("almalinux9", BASE_ALMALINUX9)
}

target "almalinux10" {
  inherits = ["_el"]
  args     = { BASE_IMAGE = BASE_ALMALINUX10 }
  tags     = ["${REGISTRY}/almalinux10:${TAG}"]
  labels   = labels("almalinux10", BASE_ALMALINUX10)
}

target "debian12" {
  inherits = ["_deb"]
  args     = { BASE_IMAGE = BASE_DEBIAN12 }
  tags     = ["${REGISTRY}/debian12:${TAG}"]
  labels   = labels("debian12", BASE_DEBIAN12)
}

target "debian13" {
  inherits = ["_deb"]
  args     = { BASE_IMAGE = BASE_DEBIAN13 }
  tags     = ["${REGISTRY}/debian13:${TAG}"]
  labels   = labels("debian13", BASE_DEBIAN13)
}

target "ubuntu2404" {
  inherits = ["_deb"]
  args     = { BASE_IMAGE = BASE_UBUNTU2404 }
  tags     = ["${REGISTRY}/ubuntu2404:${TAG}"]
  labels   = labels("ubuntu2404", BASE_UBUNTU2404)
}

target "ubuntu2604" {
  inherits = ["_deb"]
  args     = { BASE_IMAGE = BASE_UBUNTU2604 }
  tags     = ["${REGISTRY}/ubuntu2604:${TAG}"]
  labels   = labels("ubuntu2604", BASE_UBUNTU2604)
}

group "default" {
  targets = [
    "almalinux9",
    "almalinux10",
    "debian12",
    "debian13",
    "ubuntu2404",
    "ubuntu2604",
  ]
}
