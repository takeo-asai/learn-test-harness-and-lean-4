# Apple container（Docker など OCI 互換のビルダーでも可）でビルドする:
#   container build -t kvjson-harness --target harness .
#
# ステージ:
#   impl     テスト対象の CLI（Go）をビルド                -> /out/impl/kvjson
#   mutants  mutants/*.patch を 1 個ずつ当ててビルド        -> /out/mutants/<名前>
#   harness  言語非依存のハーネス（sh + jq + uv）。上の実行ファイルをコピーして使う
#   lean     おまけ。Lean の証明を検査し、Lean のモデルと CLI を比べる

FROM docker.io/library/golang:1.23.4-alpine3.21 AS impl
WORKDIR /src
COPY cli/ ./
RUN CGO_ENABLED=0 go build -trimpath -o /out/impl/kvjson .

FROM docker.io/library/golang:1.23.4-alpine3.21 AS mutants
RUN apk add --no-cache patch
WORKDIR /work
COPY cli/ ./cli/
COPY mutants/ ./mutants/
RUN set -e; mkdir -p /out/mutants; \
    for p in mutants/*.patch; do \
      name=$(basename "$p" .patch); \
      rm -rf m && cp -r cli m; \
      patch -s -d m -p1 < "$p"; \
      (cd m && CGO_ENABLED=0 go build -trimpath -o "/out/mutants/$name" .); \
    done

FROM docker.io/library/python:3.12-alpine3.21 AS harness
RUN apk add --no-cache jq
# uv で harness/pbt/props.py を実行する。依存はそのファイル先頭に書いてある（PEP 723）
COPY --from=ghcr.io/astral-sh/uv:0.5.11 /uv /bin/uv
ENV UV_PYTHON_DOWNLOADS=never UV_CACHE_DIR=/opt/uv-cache
WORKDIR /harness
COPY harness/ ./
# PBT の依存はビルド時に取得しておき、テスト実行時にはネットワークを使わない
RUN uv run --script pbt/props.py --list
ENV UV_OFFLINE=1
COPY --from=impl /out/impl/ /opt/impl/
COPY --from=mutants /out/mutants/ /opt/mutants/
ENV CLI=/opt/impl/kvjson
CMD ["./run_tests.sh"]

# --- おまけ: Lean 4 -----------------------------------------------------------
#   container build -t kvjson-lean --target lean .
# `lake build` で証明を型検査し（証明が間違っていればビルドが失敗する）、kvescape を
# コンパイルする。コンテナを実行すると kvescape と Go の CLI を比べる。
FROM docker.io/library/debian:bookworm-slim AS lean
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq \
 && rm -rf /var/lib/apt/lists/*
RUN curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
      | sh -s -- -y --default-toolchain none
ENV PATH=/root/.elan/bin:$PATH
WORKDIR /lean
COPY lean/lean-toolchain ./
RUN elan toolchain install "$(cat lean-toolchain)"
COPY lean/ ./
RUN lake build && mkdir -p /opt/lean && cp .lake/build/bin/kvescape /opt/lean/
COPY --from=impl /out/impl/ /opt/impl/
COPY --from=mutants /out/mutants/ /opt/mutants/
ENV CLI=/opt/impl/kvjson LEAN=/opt/lean/kvescape
CMD ["./diff.sh"]
