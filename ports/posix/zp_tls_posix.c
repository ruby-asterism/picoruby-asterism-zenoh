/*
 * Copyright (c) 2025 ZettaScale Technology
 * Copyright (c) 2026 Katsuhiko Kageyama (the changes described below)
 *
 * Derived from zenoh-pico 1.10.1, src/link/transport/upper/tls_stream.c, whose notice was:
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
 * TLS stream for zenoh-pico on a POSIX host (Mbed TLS 3.x over BSD
 * sockets), used by picoruby-asterism-zenoh in place of zenoh-pico's
 * src/link/transport/upper/tls_stream.c (never compiled). The link on top is
 * src/zp_tls_link.c. The same stream as ports/esp32/zp_tls_esp32.c, for a
 * polled, single-threaded session:
 *
 * 1. Nothing waits without a limit. The socket I/O under Mbed TLS never
 *    blocks (MSG_DONTWAIT); where the stream has to wait it waits on select()
 *    up to a deadline: the TLS handshake (PICORUBY_ZENOH_TLS_HANDSHAKE_TIMEOUT_MS),
 *    the handshake read (one socket timeout before the first byte, then
 *    PICORUBY_ZENOH_READ_EXACT_TIMEOUT_MS) and a send
 *    (PICORUBY_ZENOH_SEND_TIMEOUT_MS). Upstream uses a blocking socket with
 *    no limit anywhere, so a silent peer stalls the caller for good.
 * 2. The plain read (the session's read task, on every poll) never waits:
 *    SIZE_MAX when nothing has arrived, 0 when the connection is closed or
 *    failed (the gem's link contract; upstream returned 0 for "nothing yet").
 * 3. A failure ends: every Mbed TLS error other than "want read / want
 *    write" closes the read with 0 and shuts the socket down, so
 *    zp_tcp_socket_closed() reports it and the session takes zenoh-pico's
 *    failure path. An alert from the router (it refused the client's
 *    certificate, most often) is named in the log.
 * 4. Certificates and keys come from the configuration as base64 only
 *    (*_base64), as on ESP-IDF: the binding passes them that way.
 * 5. psa_crypto_init() before the first handshake when Mbed TLS has PSA
 *    (TLS 1.3 in Mbed TLS 3.x runs on it; upstream leaves it to the
 *    application).
 * 6. Client only: a TLS listener (peer mode over TLS) is refused.
 * 7. The handshake's duration and TLS version are logged once per
 *    connection.
 *
 * Differences from the ESP-IDF stream: the random generator is CTR_DRBG
 * (the one every Mbed TLS configuration has), there is no internal RAM to
 * report, and EINTR is a retry (a host scheduler may use signals).
 *
 * Off unless the host build turns TLS links on (Z_FEATURE_LINK_TLS=1) and
 * gives this file the Mbed TLS include paths and configuration; then it
 * needs Mbed TLS 3.x, with TLS 1.3 for a zenohd that asks for mutual TLS
 * (README.md, TLS). Compiled as the gem's posix port.
 */
#include "zenoh-pico/link/transport/tls_stream.h"

#if (defined(ZENOH_LINUX) || defined(ZENOH_MACOS) || defined(ZENOH_BSD)) && Z_FEATURE_LINK_TLS == 1

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>

#include "mbedtls/base64.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/error.h"
#include "mbedtls/net_sockets.h" /* MBEDTLS_ERR_NET_* (the BIO says which failure) */
#include "mbedtls/pk.h"
#include "mbedtls/ssl.h"
#include "mbedtls/version.h"
#include "mbedtls/x509_crt.h"
#include "picoruby_zenoh_link.h"
#if defined(MBEDTLS_PSA_CRYPTO_C)
#include "psa/crypto.h"
#endif
#include "zenoh-pico/config.h"
#include "zenoh-pico/link/config/tls.h"
#include "zenoh-pico/utils/logging.h"

#if MBEDTLS_VERSION_MAJOR < 3
#error "picoruby-asterism-zenoh: the POSIX TLS stream needs Mbed TLS 3.x"
#endif

/* The whole TLS handshake (from the TCP connection to the end of the
 * certificate checks). */
#ifndef PICORUBY_ZENOH_TLS_HANDSHAKE_TIMEOUT_MS
#define PICORUBY_ZENOH_TLS_HANDSHAKE_TIMEOUT_MS 10000
#endif

#define ZP_TLS_BASE64_MAX_VALUE_LEN (64 * 1024)

/* A send to a closed connection fails instead of raising SIGPIPE. */
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

struct zp_tls_context {
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context drbg;
    mbedtls_x509_crt ca;
    mbedtls_x509_crt cert;
    mbedtls_pk_context key;
    int fd; /* the BIO's socket */
};

static long zp_tls_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000L + (long)(ts.tv_nsec / 1000000L);
}

/* "-0x7780 (SSL - A fatal alert message was received from our peer)" */
static void zp_tls_errtext(int ret, char *buf, size_t len) {
    char text[96];
    mbedtls_strerror(ret, text, sizeof(text));
    snprintf(buf, len, "-0x%04x (%s)", (unsigned)-ret, text);
}

/* Wait until fd is readable (for_write false) or writable, at most
 * timeout_ms. >0 ready, 0 timeout or interrupted, <0 error. */
static int zp_tls_wait(int fd, bool for_write, int timeout_ms) {
    if (timeout_ms < 0) {
        timeout_ms = 0;
    }
    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(fd, &fds);
    struct timeval tv;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    int ret = for_write ? select(fd + 1, NULL, &fds, NULL, &tv) : select(fd + 1, &fds, NULL, NULL, &tv);
    if (ret < 0 && errno == EINTR) {
        return 0;
    }
    return ret;
}

static int zp_tls_bio_send(void *ctx, const unsigned char *buf, size_t len) {
    int fd = *(int *)ctx;
    ssize_t n = send(fd, buf, len, MSG_DONTWAIT | MSG_NOSIGNAL);
    if (n >= 0) {
        return (int)n;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        return MBEDTLS_ERR_SSL_WANT_WRITE;
    }
    return MBEDTLS_ERR_NET_SEND_FAILED;
}

static int zp_tls_bio_recv(void *ctx, unsigned char *buf, size_t len) {
    int fd = *(int *)ctx;
    ssize_t n = recv(fd, buf, len, MSG_DONTWAIT);
    if (n >= 0) {
        return (int)n; /* 0: the peer closed (Mbed TLS reports CONN_EOF) */
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        return MBEDTLS_ERR_SSL_WANT_READ;
    }
    return MBEDTLS_ERR_NET_RECV_FAILED; /* a reset: never "nothing yet" */
}

/* Nothing to do but try again later. A TLS 1.3 session ticket from the
 * router is one of them: the stream does not resume sessions. */
static bool zp_tls_want(int ret) {
    return ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE ||
           ret == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET;
}

static void zp_tls_context_free(_z_tls_context_t **pctx) {
    if (pctx == NULL || *pctx == NULL) {
        return;
    }
    _z_tls_context_t *ctx = *pctx;
    mbedtls_ssl_free(&ctx->ssl);
    mbedtls_ssl_config_free(&ctx->conf);
    mbedtls_ctr_drbg_free(&ctx->drbg);
    mbedtls_entropy_free(&ctx->entropy);
    mbedtls_x509_crt_free(&ctx->ca);
    mbedtls_x509_crt_free(&ctx->cert);
    mbedtls_pk_free(&ctx->key);
    z_free(ctx);
    *pctx = NULL;
}

static _z_tls_context_t *zp_tls_context_new(void) {
    _z_tls_context_t *ctx = (_z_tls_context_t *)z_malloc(sizeof(_z_tls_context_t));
    if (ctx == NULL) {
        return NULL;
    }
    mbedtls_ssl_init(&ctx->ssl);
    mbedtls_ssl_config_init(&ctx->conf);
    mbedtls_entropy_init(&ctx->entropy);
    mbedtls_ctr_drbg_init(&ctx->drbg);
    mbedtls_x509_crt_init(&ctx->ca);
    mbedtls_x509_crt_init(&ctx->cert);
    mbedtls_pk_init(&ctx->key);
    ctx->fd = -1;
    static const unsigned char pers[] = "picoruby-asterism-zenoh tls";
    int ret = mbedtls_ctr_drbg_seed(&ctx->drbg, mbedtls_entropy_func, &ctx->entropy, pers, sizeof(pers) - 1);
    if (ret != 0) {
        char e[128];
        zp_tls_errtext(ret, e, sizeof(e));
        _Z_ERROR("TLS: cannot seed the random generator: %s", e);
        zp_tls_context_free(&ctx);
        return NULL;
    }
    return ctx;
}

/* base64 of a PEM (or DER) from the configuration -> a NUL-terminated
 * buffer from z_malloc. */
static z_result_t zp_tls_decode(const char *label, const char *input, unsigned char **out, size_t *out_len) {
    size_t in_len = strnlen(input, ZP_TLS_BASE64_MAX_VALUE_LEN + 1);
    if (in_len > ZP_TLS_BASE64_MAX_VALUE_LEN) {
        _Z_ERROR("TLS: %s is too long", label);
        return _Z_ERR_GENERIC;
    }
    size_t need = 0;
    int ret = mbedtls_base64_decode(NULL, 0, &need, (const unsigned char *)input, in_len);
    if (ret != 0 && ret != MBEDTLS_ERR_BASE64_BUFFER_TOO_SMALL) {
        _Z_ERROR("TLS: %s is not base64: -0x%04x", label, (unsigned)-ret);
        return _Z_ERR_GENERIC;
    }
    unsigned char *buf = (unsigned char *)z_malloc(need + 1);
    if (buf == NULL) {
        return _Z_ERR_SYSTEM_OUT_OF_MEMORY;
    }
    ret = mbedtls_base64_decode(buf, need + 1, &need, (const unsigned char *)input, in_len);
    if (ret != 0) {
        _Z_ERROR("TLS: %s is not base64: -0x%04x", label, (unsigned)-ret);
        z_free(buf);
        return _Z_ERR_GENERIC;
    }
    buf[need] = '\0';
    *out = buf;
    *out_len = need;
    return _Z_RES_OK;
}

static z_result_t zp_tls_load_cert(mbedtls_x509_crt *crt, const _z_str_intmap_t *config, uint8_t key_b64,
                                   uint8_t key_path, const char *label) {
    const char *b64 = _z_str_intmap_get(config, key_b64);
    if (b64 == NULL) {
        if (_z_str_intmap_get(config, key_path) != NULL) {
            _Z_ERROR("TLS: %s must be given as base64 (no file paths)", label);
        } else {
            _Z_ERROR("TLS: %s is missing", label);
        }
        return _Z_ERR_GENERIC;
    }
    unsigned char *der = NULL;
    size_t len = 0;
    z_result_t res = zp_tls_decode(label, b64, &der, &len);
    if (res != _Z_RES_OK) {
        return res;
    }
    /* A PEM is parsed with its terminating NUL counted. */
    int ret = mbedtls_x509_crt_parse(crt, der, len + 1);
    z_free(der);
    if (ret != 0) {
        char e[128];
        zp_tls_errtext(ret, e, sizeof(e));
        _Z_ERROR("TLS: cannot read %s: %s", label, e);
        return _Z_ERR_GENERIC;
    }
    return _Z_RES_OK;
}

static z_result_t zp_tls_load_key(_z_tls_context_t *ctx, const _z_str_intmap_t *config) {
    const char *b64 = _z_str_intmap_get(config, TLS_CONFIG_CONNECT_PRIVATE_KEY_BASE64_KEY);
    if (b64 == NULL) {
        _Z_ERROR("TLS: the client private key (connect_private_key_base64) is missing");
        return _Z_ERR_GENERIC;
    }
    unsigned char *der = NULL;
    size_t len = 0;
    z_result_t res = zp_tls_decode("the client private key", b64, &der, &len);
    if (res != _Z_RES_OK) {
        return res;
    }
    int ret = mbedtls_pk_parse_key(&ctx->key, der, len + 1, NULL, 0, mbedtls_ctr_drbg_random, &ctx->drbg);
    memset(der, 0, len);
    z_free(der);
    if (ret != 0) {
        char e[128];
        zp_tls_errtext(ret, e, sizeof(e));
        _Z_ERROR("TLS: cannot read the client private key: %s", e);
        return _Z_ERR_GENERIC;
    }
    return _Z_RES_OK;
}

static bool zp_tls_opt_true(const char *val) {
    if (val == NULL || val[0] == '\0') {
        return true;
    }
    char c = val[0];
    return !(c == '0' || c == 'n' || c == 'N' || c == 'f' || c == 'F');
}

/* Mbed TLS 3.x needs PSA for TLS 1.3. Repeated calls are harmless
 * (psa_crypto_init returns at once when it is done). */
static bool zp_tls_psa_ready(void) {
#if defined(MBEDTLS_PSA_CRYPTO_C)
    psa_status_t st = psa_crypto_init();
    if (st != PSA_SUCCESS) {
        _Z_ERROR("TLS: psa_crypto_init failed: %d", (int)st);
        return false;
    }
#endif
    return true;
}

static void zp_tls_fail(_z_tls_socket_t *sock) {
    _z_tcp_close(&sock->_sock);
    zp_tls_context_free(&sock->_tls_ctx);
}

/* The alert the peer sent, when ret says one came (the description byte of
 * the last record read), else -1. */
static int zp_tls_alert(const _z_tls_context_t *ctx, int ret) {
    if (ret != MBEDTLS_ERR_SSL_FATAL_ALERT_MESSAGE || ctx == NULL) {
        return -1;
    }
    const unsigned char *msg = ctx->ssl.MBEDTLS_PRIVATE(in_msg);
    return msg != NULL ? (int)msg[1] : -1;
}

static const char *zp_tls_alert_hint(int alert) {
    switch (alert) {
        case MBEDTLS_SSL_ALERT_MSG_BAD_CERT:
        case MBEDTLS_SSL_ALERT_MSG_UNKNOWN_CA:
        case MBEDTLS_SSL_ALERT_MSG_CERT_UNKNOWN:
        case MBEDTLS_SSL_ALERT_MSG_UNSUPPORTED_CERT:
        case MBEDTLS_SSL_ALERT_MSG_CERT_REVOKED:
        case MBEDTLS_SSL_ALERT_MSG_CERT_EXPIRED:
        case MBEDTLS_SSL_ALERT_MSG_ACCESS_DENIED:
            return "the router refused this machine's certificate (not signed by the router's CA?)";
        case MBEDTLS_SSL_ALERT_MSG_CERT_REQUIRED:
            return "the router wants a client certificate and got none";
        case MBEDTLS_SSL_ALERT_MSG_PROTOCOL_VERSION:
            return "no TLS version in common with the router";
        case MBEDTLS_SSL_ALERT_MSG_HANDSHAKE_FAILURE:
            return "no cipher suite or key in common with the router";
        default:
            return "the router ended the connection";
    }
}

/* An Mbed TLS error that ends the connection: say why once, and shut the
 * socket down so zp_tcp_socket_closed() sees it. */
static void zp_tls_broken(const _z_tls_socket_t *sock, int ret) {
    int alert = zp_tls_alert(sock->_tls_ctx, ret);
    if (alert >= 0) {
        _Z_ERROR("TLS: alert %d from the router: %s", alert, zp_tls_alert_hint(alert));
    } else if (ret != 0 && ret != MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY && ret != MBEDTLS_ERR_SSL_CONN_EOF &&
               ret != MBEDTLS_ERR_NET_RECV_FAILED) {
        char e[128];
        zp_tls_errtext(ret, e, sizeof(e));
        _Z_ERROR("TLS: the connection failed: %s", e);
    }
    if (sock->_sock._fd >= 0) {
        shutdown(sock->_sock._fd, SHUT_RDWR);
    }
}

z_result_t _z_open_tls(_z_tls_socket_t *sock, const _z_sys_net_endpoint_t *rep, const char *hostname,
                       const _z_str_intmap_t *config, bool peer_socket) {
    sock->_is_peer_socket = peer_socket;
    sock->_tls_ctx = NULL;
    sock->_sock._fd = -1;
    sock->_sock._tls_sock = NULL;
    if (rep == NULL || rep->_iptcp == NULL || hostname == NULL) {
        _Z_ERROR("TLS: no address to connect to");
        return _Z_ERR_GENERIC;
    }
    if (!zp_tls_psa_ready()) {
        return _Z_ERR_GENERIC;
    }
    bool verify_name = !(_z_str_intmap_get(config, TLS_CONFIG_VERIFY_NAME_ON_CONNECT_KEY) != NULL &&
                         !zp_tls_opt_true(_z_str_intmap_get(config, TLS_CONFIG_VERIFY_NAME_ON_CONNECT_KEY)));
    const char *mtls_opt = _z_str_intmap_get(config, TLS_CONFIG_ENABLE_MTLS_KEY);
    bool mtls = mtls_opt != NULL && zp_tls_opt_true(mtls_opt);

    _z_tls_context_t *ctx = zp_tls_context_new();
    if (ctx == NULL) {
        return _Z_ERR_SYSTEM_OUT_OF_MEMORY;
    }
    sock->_tls_ctx = ctx;
    z_result_t res = zp_tls_load_cert(&ctx->ca, config, TLS_CONFIG_ROOT_CA_CERTIFICATE_BASE64_KEY,
                                      TLS_CONFIG_ROOT_CA_CERTIFICATE_KEY, "the CA certificate");
    if (res == _Z_RES_OK && mtls) {
        res = zp_tls_load_cert(&ctx->cert, config, TLS_CONFIG_CONNECT_CERTIFICATE_BASE64_KEY,
                               TLS_CONFIG_CONNECT_CERTIFICATE_KEY, "the client certificate");
        if (res == _Z_RES_OK) {
            res = zp_tls_load_key(ctx, config);
        }
    }
    if (res != _Z_RES_OK) {
        zp_tls_context_free(&sock->_tls_ctx);
        return res;
    }

    int ret = mbedtls_ssl_config_defaults(&ctx->conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM,
                                          MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret == 0) {
        mbedtls_ssl_conf_ca_chain(&ctx->conf, &ctx->ca, NULL);
        mbedtls_ssl_conf_authmode(&ctx->conf, verify_name ? MBEDTLS_SSL_VERIFY_REQUIRED : MBEDTLS_SSL_VERIFY_OPTIONAL);
        mbedtls_ssl_conf_rng(&ctx->conf, mbedtls_ctr_drbg_random, &ctx->drbg);
        if (mtls) {
            ret = mbedtls_ssl_conf_own_cert(&ctx->conf, &ctx->cert, &ctx->key);
        }
    }
    if (ret == 0) {
        ret = mbedtls_ssl_setup(&ctx->ssl, &ctx->conf);
    }
    if (ret == 0) {
        ret = mbedtls_ssl_set_hostname(&ctx->ssl, hostname);
    }
    if (ret != 0) {
        char e[128];
        zp_tls_errtext(ret, e, sizeof(e));
        _Z_ERROR("TLS: cannot set up: %s", e);
        zp_tls_context_free(&sock->_tls_ctx);
        return _Z_ERR_GENERIC;
    }

    long t0 = zp_tls_ms();
    res = _z_tcp_open(&sock->_sock, *rep, Z_CONFIG_SOCKET_TIMEOUT);
    if (res != _Z_RES_OK) {
        _Z_ERROR("TLS: cannot connect to %s (no router listening there?)", hostname);
        zp_tls_context_free(&sock->_tls_ctx);
        return res;
    }
    sock->_sock._tls_sock = (void *)sock;
    ctx->fd = sock->_sock._fd;
    mbedtls_ssl_set_bio(&ctx->ssl, &ctx->fd, zp_tls_bio_send, zp_tls_bio_recv, NULL);

    long deadline = t0 + PICORUBY_ZENOH_TLS_HANDSHAKE_TIMEOUT_MS;
    for (;;) {
        ret = mbedtls_ssl_handshake(&ctx->ssl);
        if (ret == 0) {
            break;
        }
        long left = deadline - zp_tls_ms();
        if (!zp_tls_want(ret) || left <= 0) {
            if (left <= 0 && zp_tls_want(ret)) {
                _Z_ERROR("TLS: the handshake with %s took longer than %d ms", hostname,
                         PICORUBY_ZENOH_TLS_HANDSHAKE_TIMEOUT_MS);
            } else {
                int alert = zp_tls_alert(ctx, ret);
                if (alert >= 0) {
                    _Z_ERROR("TLS: the handshake with %s failed: alert %d: %s", hostname, alert,
                             zp_tls_alert_hint(alert));
                } else {
                    char e[128];
                    zp_tls_errtext(ret, e, sizeof(e));
                    _Z_ERROR("TLS: the handshake with %s failed: %s (verify 0x%08x)", hostname, e,
                             (unsigned)mbedtls_ssl_get_verify_result(&ctx->ssl));
                }
            }
            zp_tls_fail(sock);
            return _Z_ERR_GENERIC;
        }
        if (zp_tls_wait(ctx->fd, ret == MBEDTLS_ERR_SSL_WANT_WRITE, (int)left) < 0) {
            _Z_ERROR("TLS: the connection to %s failed during the handshake", hostname);
            zp_tls_fail(sock);
            return _Z_ERR_GENERIC;
        }
    }

    uint32_t flags = mbedtls_ssl_get_verify_result(&ctx->ssl);
    uint32_t ignored = verify_name ? 0u : MBEDTLS_X509_BADCERT_CN_MISMATCH;
    if ((flags & ~ignored) != 0u) {
        _Z_ERROR("TLS: the router's certificate is not trusted: 0x%08x", (unsigned)flags);
        zp_tls_fail(sock);
        return _Z_ERR_GENERIC;
    }
    printf("zenoh: TLS handshake with %s (%s) took %ld ms\n", hostname, mbedtls_ssl_get_version(&ctx->ssl),
           zp_tls_ms() - t0);
    return _Z_RES_OK;
}

z_result_t _z_listen_tls(_z_tls_socket_t *sock, const _z_sys_net_endpoint_t *rep, const _z_str_intmap_t *config) {
    _ZP_UNUSED(rep);
    _ZP_UNUSED(config);
    sock->_tls_ctx = NULL;
    sock->_is_peer_socket = false;
    _Z_ERROR("TLS: listening (a TLS peer) is not supported by this build");
    return _Z_ERR_GENERIC;
}

z_result_t _z_tls_accept(_z_sys_net_socket_t *socket, const _z_sys_net_socket_t *listen_sock) {
    _ZP_UNUSED(socket);
    _ZP_UNUSED(listen_sock);
    return _Z_ERR_GENERIC;
}

void _z_close_tls_socket(_z_sys_net_socket_t *socket) {
    if (socket == NULL || socket->_tls_sock == NULL) {
        return;
    }
    _z_tls_socket_t *tls_sock = (_z_tls_socket_t *)socket->_tls_sock;
    bool peer_socket = tls_sock->_is_peer_socket;
    _z_close_tls(tls_sock);
    if (peer_socket) {
        z_free(tls_sock);
    }
    socket->_tls_sock = NULL;
    socket->_fd = -1;
}

void _z_close_tls(_z_tls_socket_t *sock) {
    if (sock->_tls_ctx != NULL) {
        /* One try, never waits (the socket is non-blocking for Mbed TLS). */
        (void)mbedtls_ssl_close_notify(&sock->_tls_ctx->ssl);
        zp_tls_context_free(&sock->_tls_ctx);
    }
    _z_tcp_close(&sock->_sock);
    sock->_sock._tls_sock = NULL;
}

size_t _z_read_tls(const _z_tls_socket_t *sock, uint8_t *ptr, size_t len) {
    if (sock->_tls_ctx == NULL) {
        return 0;
    }
    int ret = mbedtls_ssl_read(&sock->_tls_ctx->ssl, ptr, len);
    if (ret > 0) {
        return (size_t)ret;
    }
    if (zp_tls_want(ret)) {
        return SIZE_MAX;
    }
    zp_tls_broken(sock, ret);
    return 0;
}

size_t zp_tls_read_exact(const _z_tls_socket_t *sock, uint8_t *ptr, size_t len) {
    if (sock->_tls_ctx == NULL) {
        return 0;
    }
    size_t n = 0;
    long started = 0;
    bool waited = false;
    while (n < len) {
        int ret = mbedtls_ssl_read(&sock->_tls_ctx->ssl, ptr + n, len - n);
        if (ret > 0) {
            if (n == 0) {
                started = zp_tls_ms();
            }
            n += (size_t)ret;
            continue;
        }
        if (!zp_tls_want(ret)) {
            zp_tls_broken(sock, ret);
            return 0;
        }
        if (ret == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) {
            continue; /* a record was consumed: read again at once */
        }
        /* Before the first byte: wait one socket timeout, then report a
         * timeout (the caller loops until its own deadline). After it: keep
         * waiting so the message is not cut in half. */
        int wait_ms;
        if (n == 0) {
            if (waited) {
                return SIZE_MAX;
            }
            waited = true;
            wait_ms = Z_CONFIG_SOCKET_TIMEOUT;
        } else {
            long left = PICORUBY_ZENOH_READ_EXACT_TIMEOUT_MS - (zp_tls_ms() - started);
            if (left <= 0) {
                return SIZE_MAX;
            }
            wait_ms = (int)left;
        }
        if (zp_tls_wait(sock->_tls_ctx->fd, ret == MBEDTLS_ERR_SSL_WANT_WRITE, wait_ms) < 0) {
            zp_tls_broken(sock, 0);
            return 0;
        }
    }
    return n;
}

size_t _z_write_tls(const _z_tls_socket_t *sock, const uint8_t *ptr, size_t len) {
    if (sock->_tls_ctx == NULL) {
        return SIZE_MAX;
    }
    long deadline = zp_tls_ms() + PICORUBY_ZENOH_SEND_TIMEOUT_MS;
    size_t n = 0;
    while (n < len) {
        int ret = mbedtls_ssl_write(&sock->_tls_ctx->ssl, ptr + n, len - n);
        if (ret > 0) {
            n += (size_t)ret;
            continue;
        }
        long left = deadline - zp_tls_ms();
        if (zp_tls_want(ret) && left > 0 &&
            zp_tls_wait(sock->_tls_ctx->fd, ret == MBEDTLS_ERR_SSL_WANT_WRITE, (int)left) >= 0) {
            continue;
        }
        /* Part of a record may be on the wire: the stream is unusable. */
        zp_tls_broken(sock, zp_tls_want(ret) ? 0 : ret);
        return SIZE_MAX;
    }
    return n;
}

size_t _z_write_all_tls(const _z_tls_socket_t *sock, const uint8_t *ptr, size_t len) {
    return _z_write_tls(sock, ptr, len);
}

#endif /* POSIX && Z_FEATURE_LINK_TLS == 1 */
