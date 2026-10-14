/* Test only: the platform's default namespace of picoruby-asterism-zenoh
 * (include/picoruby_zenoh_link.h), set from Ruby with
 * PZTest.default_namespace = "room/a" (nil for none). */
#include <string.h>

#include <mruby.h>
#include <mruby/string.h>

static char s_ns[128];
static int s_set;

const char *picoruby_zenoh_default_namespace(void) { return s_set ? s_ns : NULL; }

static mrb_value pz_set_default_namespace(mrb_state *mrb, mrb_value self) {
    mrb_value v;
    mrb_get_args(mrb, "o", &v);
    if (mrb_nil_p(v)) {
        s_set = 0;
        return v;
    }
    const char *p = mrb_string_value_cstr(mrb, &v);
    size_t n = strlen(p);
    if (n >= sizeof(s_ns)) {
        mrb_raise(mrb, E_ARGUMENT_ERROR, "too long");
    }
    memcpy(s_ns, p, n + 1);
    s_set = 1;
    return v;
}

void mrb_pz_test_ns_hook_gem_init(mrb_state *mrb) {
    struct RClass *m = mrb_define_module(mrb, "PZTest");
    mrb_define_module_function(mrb, m, "default_namespace=", pz_set_default_namespace, MRB_ARGS_REQ(1));
}

void mrb_pz_test_ns_hook_gem_final(mrb_state *mrb) { (void)mrb; }
