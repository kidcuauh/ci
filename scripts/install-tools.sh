#!/usr/bin/env bash
# Instala herramientas fijadas por versión y sha256 (verificado antes de ejecutarlas).
# Uso: install-tools.sh <herramienta>... (helm flux kubeconform gitleaks yq cosign kind kubectl)
# Destino: $TOOLS_BIN, o $RUNNER_TEMP/bin en Actions. Si existe $GITHUB_PATH, lo agrega.
# Plataformas: linux/amd64 (runners) y darwin/arm64 (local). Las versiones y hashes
# se actualizan a mano: Dependabot no los ve.
set -euo pipefail

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) plat=linux ;;
  Darwin/arm64) plat=darwin ;;
  *)
    echo "plataforma no soportada: $(uname -s)/$(uname -m)" >&2
    exit 2
    ;;
esac

bin="${TOOLS_BIN:-${RUNNER_TEMP:-}/bin}"
[[ "$bin" != /bin ]] || {
  echo "define TOOLS_BIN (o RUNNER_TEMP en Actions)" >&2
  exit 2
}
mkdir -p "$bin"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sha256_check() { # sha archivo
  if command -v sha256sum >/dev/null; then
    echo "$1  $2" | sha256sum -c - >/dev/null
  else
    echo "$1  $2" | shasum -a 256 -c - >/dev/null
  fi
}

fetch() { # url sha archivo
  curl -fsSL --retry 3 --retry-all-errors -o "$3" "$1"
  sha256_check "$2" "$3" || {
    echo "sha256 no coincide: $1" >&2
    exit 1
  }
}

# untar archivo.tar.gz nombre-del-binario
untar() {
  local d="$work/x-$2"
  mkdir -p "$d"
  tar -xzf "$1" -C "$d"
  install -m 0755 "$(find "$d" -type f -name "$2" | head -n 1)" "$bin/$2"
}

for tool in "$@"; do
  case "$tool/$plat" in
    helm/linux) fetch https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz 0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b "$work/t.tgz" && untar "$work/t.tgz" helm ;;
    helm/darwin) fetch https://get.helm.sh/helm-v4.3.1-darwin-arm64.tar.gz 6b4e61c8cd27d99e5a801e63ff25dd5c70b36875c2cd659d3e9ce6b76fc23198 "$work/t.tgz" && untar "$work/t.tgz" helm ;;
    flux/linux) fetch https://github.com/fluxcd/flux2/releases/download/v2.10.0/flux_2.10.0_linux_amd64.tar.gz 208dd7012c04fedeed5b2d0b6e63df3b15b1c34a381527811685c098bc9f8659 "$work/t.tgz" && untar "$work/t.tgz" flux ;;
    flux/darwin) fetch https://github.com/fluxcd/flux2/releases/download/v2.10.0/flux_2.10.0_darwin_arm64.tar.gz 339c5dba218e2b0a04a0841d1dace6c00d65736dc3286038463fa86754ff6c53 "$work/t.tgz" && untar "$work/t.tgz" flux ;;
    kubeconform/linux) fetch https://github.com/yannh/kubeconform/releases/download/v0.8.0/kubeconform-linux-amd64.tar.gz 9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883 "$work/t.tgz" && untar "$work/t.tgz" kubeconform ;;
    kubeconform/darwin) fetch https://github.com/yannh/kubeconform/releases/download/v0.8.0/kubeconform-darwin-arm64.tar.gz f84f4dfbebf4a6b0b230385fa065a39ea35e02608c2b50d025dcf64775a69d67 "$work/t.tgz" && untar "$work/t.tgz" kubeconform ;;
    gitleaks/linux) fetch https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz 551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb "$work/t.tgz" && untar "$work/t.tgz" gitleaks ;;
    gitleaks/darwin) fetch https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_darwin_arm64.tar.gz b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5 "$work/t.tgz" && untar "$work/t.tgz" gitleaks ;;
    yq/linux) fetch https://github.com/mikefarah/yq/releases/download/v4.54.1/yq_linux_amd64 8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f "$work/yq" && install -m 0755 "$work/yq" "$bin/yq" ;;
    yq/darwin) fetch https://github.com/mikefarah/yq/releases/download/v4.54.1/yq_darwin_arm64 fee511a181bd8b3e6b7da98842b41973bfac8cd3bcd341ed29a584620b5b2844 "$work/yq" && install -m 0755 "$work/yq" "$bin/yq" ;;
    cosign/linux) fetch https://github.com/sigstore/cosign/releases/download/v3.1.4/cosign-linux-amd64 424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa "$work/cosign" && install -m 0755 "$work/cosign" "$bin/cosign" ;;
    cosign/darwin) fetch https://github.com/sigstore/cosign/releases/download/v3.1.4/cosign-darwin-arm64 9f9b8cd557cf2e5b3df3373a00baa005a86b02391e3e06dd0ce37b3a1533d3a4 "$work/cosign" && install -m 0755 "$work/cosign" "$bin/cosign" ;;
    kind/linux) fetch https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64 aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d "$work/kind" && install -m 0755 "$work/kind" "$bin/kind" ;;
    kind/darwin) fetch https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-darwin-arm64 0c8c7dbe5e23594a198b786c4bc13dacc101fa6196b0cb0b23a1ca44e61f4b4f "$work/kind" && install -m 0755 "$work/kind" "$bin/kind" ;;
    kubectl/linux) fetch https://dl.k8s.io/release/v1.36.6/bin/linux/amd64/kubectl 29818b6729dc9262b692307470d0558d027725e738be5dd47c760261868a2634 "$work/kubectl" && install -m 0755 "$work/kubectl" "$bin/kubectl" ;;
    kubectl/darwin) fetch https://dl.k8s.io/release/v1.36.6/bin/darwin/arm64/kubectl 1cf735c3d35ccfec28d0618784cb06a4614d2c42aade28b6be0eab76a2ffb623 "$work/kubectl" && install -m 0755 "$work/kubectl" "$bin/kubectl" ;;
    *)
      echo "herramienta desconocida: $tool" >&2
      exit 2
      ;;
  esac
  echo "instalado: $tool"
done

if [[ -n "${GITHUB_PATH:-}" ]]; then echo "$bin" >>"$GITHUB_PATH"; fi
