/*
 * Copyright (c) 2025 ZettaScale Technology
 * Copyright (c) 2026 Katsuhiko Kageyama (the changes described below)
 *
 * Derived from zenoh-pico 1.10.1, include/zenoh-pico/link/transport/tls_stream.h, whose notice was:
 *
 *   Copyright (c) 2025 ZettaScale Technology
 *
 *   This program and the accompanying materials are made available under the
 *   terms of the Eclipse Public License 2.0 which is available at
 *   http://www.eclipse.org/legal/epl-2.0, or the Apache License, Version 2.0
 *   which is available at https://www.apache.org/licenses/LICENSE-2.0.
 *
 *   SPDX-License-Identifier: EPL-2.0 OR Apache-2.0
 *
 *   Contributors:
 *     ZettaScale Zenoh Team, <zenoh@zettascale.tech>
 *
 * Of zenoh-pico's two licenses, this repository uses the Apache License,
 * Version 2.0 (LICENSE-APACHE; zenoh-pico's notices are in NOTICE). This
 * file has been modified (see below) and is distributed under the Apache
 * License, Version 2.0, not under this repository's MIT license.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * The TLS stream, as the zenoh-pico core sees it, on every platform.
 *
 * zenoh-pico's link.h includes this header, and zenoh-pico's own version
 * includes the Mbed TLS headers to lay out the TLS context. The core is
 * compiled by the mruby build, which has no Mbed TLS include paths (on
 * ESP-IDF the bare cross compiler has no ESP-IDF headers at all). The core
 * never looks inside the context (it only calls the functions below), so
 * here the context is an incomplete type, defined by the platform's stream:
 * ports/esp32/zp_tls_esp32.c (compiled by the ESP-IDF component) or
 * ports/posix/zp_tls_posix.c (compiled with the Mbed TLS headers the host
 * build gives it). This directory comes before zenoh-pico's include/ on the
 * include path, so this file is the one found; nothing in the zenoh-pico
 * checkout is edited, and zenoh-pico's own TLS link and stream are never
 * compiled. Without TLS links (Z_FEATURE_LINK_TLS 0) it declares nothing.
 */
#ifndef ZENOH_PICO_LINK_TRANSPORT_TLS_STREAM_H
#define ZENOH_PICO_LINK_TRANSPORT_TLS_STREAM_H

#include <stdbool.h>
#include <stdint.h>

#include "zenoh-pico/collections/string.h"
#include "zenoh-pico/link/transport/tcp.h"

#ifdef __cplusplus
extern "C" {
#endif

#if Z_FEATURE_LINK_TLS == 1

/* Defined by the platform's stream (ports/esp32, ports/posix; Mbed TLS state). */
typedef struct zp_tls_context _z_tls_context_t;

typedef struct {
    _z_sys_net_socket_t _sock;
    _z_tls_context_t *_tls_ctx;
    bool _is_peer_socket;  // a peer socket allocated in heap, needs to be freed in _z_close_tls
} _z_tls_socket_t;

z_result_t _z_open_tls(_z_tls_socket_t *sock, const _z_sys_net_endpoint_t *rep, const char *hostname,
                       const _z_str_intmap_t *config, bool peer_socket);
z_result_t _z_listen_tls(_z_tls_socket_t *sock, const _z_sys_net_endpoint_t *rep, const _z_str_intmap_t *config);
z_result_t _z_tls_accept(_z_sys_net_socket_t *socket, const _z_sys_net_socket_t *listen_sock);
void _z_close_tls_socket(_z_sys_net_socket_t *socket);
void _z_close_tls(_z_tls_socket_t *sock);
/* The polled read: never waits. SIZE_MAX when nothing has arrived yet, 0
 * when the connection is closed or failed, else the byte count (the same
 * contract as this gem's TCP link, include/picoruby_zenoh_link.h). */
size_t _z_read_tls(const _z_tls_socket_t *sock, uint8_t *ptr, size_t len);
/* The handshake read: len bytes, or SIZE_MAX when nothing came within one
 * socket timeout (the caller loops until its own deadline) or a started
 * message did not complete in time, or 0 when the connection is closed or
 * failed (like _z_tcp_read_exact). */
size_t zp_tls_read_exact(const _z_tls_socket_t *sock, uint8_t *ptr, size_t len);
/* Sends all of it within PICORUBY_ZENOH_SEND_TIMEOUT_MS, else shuts the
 * socket down and returns SIZE_MAX. */
size_t _z_write_tls(const _z_tls_socket_t *sock, const uint8_t *ptr, size_t len);
size_t _z_write_all_tls(const _z_tls_socket_t *sock, const uint8_t *ptr, size_t len);

#endif  // Z_FEATURE_LINK_TLS == 1

#ifdef __cplusplus
}
#endif

#endif /* ZENOH_PICO_LINK_TRANSPORT_TLS_STREAM_H */
