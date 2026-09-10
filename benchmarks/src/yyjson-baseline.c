/* Pure-C yyjson baseline for the Lua package's benchmarks.
 *
 * Measures the same three things the Lua side measures, on the same bytes:
 *   1. parse          text  -> yyjson tree   (yyjson_read_opts, as Lua calls it)
 *   2. parse + scrape tree  -> one nested field
 *   3. encode         tree  -> text          (yyjson_write_opts on a parsed doc)
 *
 * The fixtures come from fixtures.json, which is the JSON document the Lua
 * benchmarks build, so both sides read identical input.
 *
 * Bytes for step 3 are freed every iteration, matching the Lua side, which gets
 * a fresh Lua string back.
 *
 * Prints JSON on stdout for the Lua driver to read.
 */

#define _POSIX_C_SOURCE 199309L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "yyjson.h"

#define READ_FLAGS (YYJSON_READ_ALLOW_TRAILING_COMMAS | YYJSON_READ_ALLOW_COMMENTS | \
    YYJSON_READ_ALLOW_INF_AND_NAN | YYJSON_READ_ALLOW_EXT_NUMBER |                   \
    YYJSON_READ_ALLOW_EXT_ESCAPE | YYJSON_READ_ALLOW_EXT_WHITESPACE |               \
    YYJSON_READ_ALLOW_SINGLE_QUOTED_STR | YYJSON_READ_ALLOW_UNQUOTED_KEY)

typedef struct {
    const char *name;
    const char *json;
    size_t len;
} Fixture;

static double nowNs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e9 + (double)ts.tv_nsec;
}

static yyjson_doc *parse(const Fixture *f) {
    yyjson_doc *doc = yyjson_read_opts((char *)f->json, f->len, READ_FLAGS, NULL, NULL);
    if (!doc) abort();
    return doc;
}

static char *readFile(const char *path, size_t *outLen) {
    FILE *fp = fopen(path, "rb");
    if (!fp) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
    fseek(fp, 0, SEEK_END);
    long len = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    char *buf = (char *)malloc((size_t)len + 1);
    if (fread(buf, 1, (size_t)len, fp) != (size_t)len) exit(1);
    buf[len] = '\0';
    fclose(fp);
    if (outLen) *outLen = (size_t)len;
    return buf;
}

typedef struct {
    double parse;
    double scrape;
    double encode;
} Timings;

static double timeIt(size_t iters, void (*step)(const Fixture *, yyjson_doc *), const Fixture *f, yyjson_doc *doc) {
    for (size_t i = 0; i < iters / 10 + 1; i++) step(f, doc);
    double t0 = nowNs();
    for (size_t i = 0; i < iters; i++) step(f, doc);
    return (nowNs() - t0) / (double)iters;
}

static void stepParse(const Fixture *f, yyjson_doc *unused) {
    (void)unused;
    yyjson_doc_free(parse(f));
}

static void stepScrapeSmall(const Fixture *f, yyjson_doc *unused) {
    (void)unused;
    yyjson_doc *doc = parse(f);
    yyjson_val *v = yyjson_obj_get(yyjson_doc_get_root(doc), "name");
    if (!yyjson_get_str(v)) abort();
    yyjson_doc_free(doc);
}

static void stepScrapeMedium(const Fixture *f, yyjson_doc *unused) {
    (void)unused;
    yyjson_doc *doc = parse(f);
    yyjson_val *users = yyjson_obj_get(yyjson_doc_get_root(doc), "users");
    yyjson_val *user = yyjson_arr_get(users, 9);
    if (!yyjson_get_str(yyjson_obj_get(user, "name"))) abort();
    yyjson_doc_free(doc);
}

static void stepScrapeLarge(const Fixture *f, yyjson_doc *unused) {
    (void)unused;
    yyjson_doc *doc = parse(f);
    yyjson_val *item = yyjson_arr_get(yyjson_doc_get_root(doc), 249);
    yyjson_val *tags = yyjson_obj_get(item, "tags");
    if (!yyjson_get_str(yyjson_arr_get(tags, 1))) abort();
    yyjson_doc_free(doc);
}

static void stepEncode(const Fixture *f, yyjson_doc *doc) {
    (void)f;
    size_t len = 0;
    char *out = yyjson_write_opts(doc, 0, NULL, &len, NULL);
    if (!out) abort();
    free(out);
}

static Timings measure(const char *name, const Fixture *f, size_t iters,
                       void (*scrape)(const Fixture *, yyjson_doc *)) {
    Timings t;
    t.parse = timeIt(iters, stepParse, f, NULL);
    t.scrape = timeIt(iters, scrape, f, NULL);
    yyjson_doc *doc = parse(f);
    t.encode = timeIt(iters, stepEncode, f, doc);
    yyjson_doc_free(doc);
    (void)name;
    return t;
}

static void emit(const char *name, Timings t) {
    printf("  { \"name\": \"%s\", \"parse\": %.2f, \"scrape\": %.2f, \"encode\": %.2f }", name, t.parse, t.scrape, t.encode);
}

int main(int argc, char **argv) {
    const char *fixturesPath = argc > 1 ? argv[1] : "fixtures.json";
    size_t docLen = 0;
    char *docText = readFile(fixturesPath, &docLen);

    yyjson_doc *doc = yyjson_read_opts(docText, docLen, 0, NULL, NULL);
    if (!doc) { fprintf(stderr, "fixtures.json is not valid JSON\n"); return 1; }
    yyjson_val *root = yyjson_doc_get_root(doc);

#define STR(key) yyjson_get_str(yyjson_obj_get(root, key))
    Fixture fixtures[3] = {
        { "small",  STR("small"),  0 },
        { "medium", STR("medium"), 0 },
        { "large",  STR("large"),  0 },
    };
#undef STR
    for (int i = 0; i < 3; i++) fixtures[i].len = strlen(fixtures[i].json);

    size_t iters[3] = { 20000, 2000, 100 };
    void (*scrapers[3])(const Fixture *, yyjson_doc *) = { stepScrapeSmall, stepScrapeMedium, stepScrapeLarge };

    printf("{\n");
    for (int i = 0; i < 3; i++) {
        Timings t = measure(fixtures[i].name, &fixtures[i], iters[i], scrapers[i]);
        emit(fixtures[i].name, t);
        printf("%s\n", i < 2 ? "," : "");
    }
    printf("}\n");

    yyjson_doc_free(doc);
    free(docText);
    return 0;
}
