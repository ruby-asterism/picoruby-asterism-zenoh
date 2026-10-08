/*
 * Copyright (c) 2022 ZettaScale Technology
 * Copyright (c) 2026 Katsuhiko Kageyama (the changes described below)
 *
 * Derived from zenoh-pico 1.10.1, include/zenoh-pico/system/platform/espidf.h, whose notice was:
 *
 *   Copyright (c) 2022 ZettaScale Technology
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
 * zenoh-pico platform types for ESP-IDF, without the ESP-IDF headers.
 *
 * zenoh-pico's own ESP-IDF header (zenoh-pico/system/platform/espidf.h)
 * includes FreeRTOS and the UART driver. In a PicoRuby ESP-IDF build the
 * zenoh-pico core is compiled by the mruby build with the bare cross compiler,
 * which has no ESP-IDF include paths; only the platform files (system, TCP,
 * socket) are compiled by the ESP-IDF component. zenoh_generic_config.h points
 * ZP_SYSTEM_PLATFORM_HEADER here for ZENOH_ESPIDF, so both sides see these
 * same types.
 *
 * The layout matches espidf.h for this gem's configuration (single-threaded,
 * TCP only, no serial): a socket is an lwIP file descriptor and an endpoint
 * the getaddrinfo() result. Keep it in step with that header when zenoh-pico
 * is updated.
 */
#ifndef PICORUBY_ZENOH_ESPIDF_PLATFORM_H
#define PICORUBY_ZENOH_ESPIDF_PLATFORM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/time.h>
#include <time.h>

#include "zenoh-pico/config.h"

#if Z_FEATURE_MULTI_THREAD == 1
#error "picoruby-asterism-zenoh: the ESP-IDF platform header supports the single-threaded build only"
#endif
#if Z_FEATURE_LINK_SERIAL == 1 || Z_FEATURE_LINK_BLUETOOTH == 1 || Z_FEATURE_RAWETH_TRANSPORT == 1 || \
    Z_FEATURE_LINK_TLS == 1
#error "picoruby-asterism-zenoh: the ESP-IDF platform header supports socket links (TCP/UDP) only"
#endif

#ifdef __cplusplus
extern "C" {
#endif

struct addrinfo;

typedef struct timespec z_clock_t;
typedef struct timeval z_time_t;

typedef struct {
    union {
#if defined(ZP_PLATFORM_SOCKET_LINKS_ENABLED)
        int _fd;
#endif
    };
} _z_sys_net_socket_t;

typedef struct {
    union {
#if defined(ZP_PLATFORM_SOCKET_LINKS_ENABLED)
        struct addrinfo *_iptcp;
#endif
    };
} _z_sys_net_endpoint_t;

#ifdef __cplusplus
}
#endif

#endif /* PICORUBY_ZENOH_ESPIDF_PLATFORM_H */
