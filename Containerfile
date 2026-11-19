FROM ghcr.io/anomalyco/opencode:1.19.6 AS builder

# The upstream executable is linked against musl and its C++ runtime.
# Keep those libraries separate from UBI's glibc libraries.
RUN mkdir -p /tmp/opencode-runtime/loader /tmp/opencode-runtime/libraries /tmp/opencode-runtime/etc && \
    cp -L /lib/ld-musl-*.so.1 /tmp/opencode-runtime/loader/ && \
    cp -L /usr/lib/libstdc++.so.6 /usr/lib/libgcc_s.so.1 /tmp/opencode-runtime/libraries/ && \
    for loader in /lib/ld-musl-*.so.1; do \
      arch="${loader##*ld-musl-}"; arch="${arch%.so.1}"; \
      printf '%s\n' /opt/opencode/lib > "/tmp/opencode-runtime/etc/ld-musl-${arch}.path"; \
    done

FROM registry.access.redhat.com/ubi10/ubi-minimal:latest

# Copy OpenCode and its isolated musl runtime.
COPY --from=builder /usr/local/bin/opencode /usr/local/bin/opencode
COPY --from=builder /tmp/opencode-runtime/loader/ /lib/
COPY --from=builder /tmp/opencode-runtime/libraries/ /opt/opencode/lib/
COPY --from=builder /tmp/opencode-runtime/etc/ /etc/

# Install git, curl, wget, skopeo, and clean up the cache
RUN microdnf update -y && \
    microdnf install -y git curl wget skopeo && \
    microdnf clean all

# OpenShift runs containers with an arbitrary UID in group 0.
RUN mkdir -p /home/opencode && chgrp 0 /home/opencode && chmod g=u /home/opencode
ENV HOME=/home/opencode

# Run as a non-root user for security/OpenShift compatibility
USER 1000

# The setup job invokes OpenCode through Bash; catch missing ELF loaders at build time.
RUN /bin/bash -lc '/usr/local/bin/opencode --version'

ENTRYPOINT ["opencode"]
