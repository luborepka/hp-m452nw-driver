#include "PrinterBridge.h"
#include <cups/cups.h>
#include <cups/http.h>
#include <cups/ipp.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>

typedef struct { http_t *http; char resource[1024]; } Connection;

static Connection connect_printer(const char *uri, char *error, size_t length) {
    Connection c = {0};
    char scheme[16], user[256], host[1024]; int port;
    if (httpSeparateURI(HTTP_URI_CODING_ALL, uri, scheme, sizeof scheme,
                       user, sizeof user, host, sizeof host, &port,
                       c.resource, sizeof c.resource) < HTTP_URI_STATUS_OK ||
        (strcmp(scheme, "ipp") && strcmp(scheme, "ipps"))) {
        snprintf(error, length, "Expected an ipp:// or ipps:// printer address.");
        return c;
    }
    c.http = httpConnect2(host, port, NULL, AF_UNSPEC,
                         !strcmp(scheme, "ipps") ? HTTP_ENCRYPTION_ALWAYS : HTTP_ENCRYPTION_IF_REQUESTED,
                         1, 5000, NULL);
    if (!c.http) snprintf(error, length, "Cannot connect to printer: %s", cupsLastErrorString());
    else httpSetTimeout(c.http, 20, NULL, NULL);
    return c;
}

static ipp_t *request(ipp_op_t op, const char *uri) {
    ipp_t *r = ippNewRequest(op);
    ippSetVersion(r, 1, 1);
    ippAddString(r, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, uri);
    ippAddString(r, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, cupsUser());
    return r;
}

static int response_ok(ipp_t *r, char *error, size_t length) {
    if (!r || ippGetStatusCode(r) >= IPP_STATUS_ERROR_BAD_REQUEST) {
        snprintf(error, length, "%s", cupsLastErrorString());
        return 0;
    }
    return 1;
}

static int contains(ipp_t *r, const char *name, const char *value) {
    ipp_attribute_t *a = ippFindAttribute(r, name, IPP_TAG_ZERO);
    for (int i = 0; a && i < ippGetCount(a); i++) {
        const char *s = ippGetString(a, i, NULL);
        if (s && !strcmp(s, value)) return 1;
    }
    return 0;
}

static void attribute_text(ipp_t *r, const char *name, char *out, size_t length) {
    ipp_attribute_t *a = ippFindAttribute(r, name, IPP_TAG_ZERO);
    out[0] = 0;
    if (a) ippAttributeString(a, out, length);
}

int hp_probe(const char *uri, HPPrinterInfo *info, char *error, size_t length) {
    memset(info, 0, sizeof *info);
    info->tray1_loaded = -1;
    Connection c = connect_printer(uri, error, length);
    if (!c.http) return 0;
    ipp_t *q = request(IPP_OP_GET_PRINTER_ATTRIBUTES, uri);
    // Avoid requesting "all": old HP firmware emits malformed scoped IPv6
    // supply-info URIs and an enormous media-col-database in that response.
    const char *attrs[] = {"printer-make-and-model", "printer-state", "printer-state-reasons",
        "printer-is-accepting-jobs", "document-format-supported", "media-source-supported", "printer-input-tray"};
    ippAddStrings(q, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", 7, NULL, attrs);
    ipp_t *r = cupsDoRequest(c.http, q, c.resource);
    int ok = response_ok(r, error, length);
    if (ok) {
        attribute_text(r, "printer-make-and-model", info->model, sizeof info->model);
        attribute_text(r, "printer-state-reasons", info->reasons, sizeof info->reasons);
        info->state = ippGetInteger(ippFindAttribute(r, "printer-state", IPP_TAG_ENUM), 0);
        info->accepting = ippGetBoolean(ippFindAttribute(r, "printer-is-accepting-jobs", IPP_TAG_BOOLEAN), 0);
        info->pdf = contains(r, "document-format-supported", "application/pdf");
        info->tray1 = contains(r, "media-source-supported", "tray-1");
        ipp_attribute_t *trays = ippFindAttribute(r, "printer-input-tray", IPP_TAG_STRING);
        for (int i = 0; trays && i < ippGetCount(trays); i++) {
            int count = 0;
            const char *bytes = ippGetOctetString(trays, i, &count);
            char tray[1024];
            if (!bytes || count <= 0) continue;
            snprintf(tray, sizeof tray, "%.*s", count, bytes);
            if (strstr(tray, "name=tray-1;")) {
                const char *level = strstr(tray, ";level=");
                if (level) {
                    int value = -2;
                    if (sscanf(level, ";level=%d", &value) == 1) {
                        if (value == 0) info->tray1_loaded = 0;
                        else if (value > 0 || value == -3) info->tray1_loaded = 1;
                    }
                }
            }
        }
    }
    ippDelete(r); httpClose(c.http);
    return ok;
}

int hp_submit(const char *uri, const char *file, const char *title,
              const char *media, const char *source, const char *color,
              char *error, size_t length) {
    Connection c = connect_printer(uri, error, length);
    if (!c.http) return -1;
    ipp_t *q = request(IPP_OP_PRINT_JOB, uri);
    ippAddString(q, IPP_TAG_OPERATION, IPP_TAG_NAME, "job-name", NULL, title);
    ippAddString(q, IPP_TAG_OPERATION, IPP_TAG_MIMETYPE, "document-format", NULL, "application/pdf");
    ippAddBoolean(q, IPP_TAG_OPERATION, "ipp-attribute-fidelity", 1);
    ippAddInteger(q, IPP_TAG_JOB, IPP_TAG_INTEGER, "copies", 1);
    ippAddString(q, IPP_TAG_JOB, IPP_TAG_KEYWORD, "sides", NULL, "one-sided");
    ippAddString(q, IPP_TAG_JOB, IPP_TAG_KEYWORD, "print-color-mode", NULL, color);
    ippAddString(q, IPP_TAG_JOB, IPP_TAG_KEYWORD, "print-scaling", NULL, "fit");
    ipp_t *collection = ippNew();
    ipp_t *size = ippNew();
    int width = !strcmp(media, "na_letter_8.5x11in") ? 21590 : 21000;
    int height = !strcmp(media, "na_letter_8.5x11in") ? 27940 : 29700;
    ippAddInteger(size, IPP_TAG_ZERO, IPP_TAG_INTEGER, "x-dimension", width);
    ippAddInteger(size, IPP_TAG_ZERO, IPP_TAG_INTEGER, "y-dimension", height);
    ippAddCollection(collection, IPP_TAG_ZERO, "media-size", size);
    ippDelete(size);
    ippAddString(collection, IPP_TAG_ZERO, IPP_TAG_KEYWORD, "media-source", NULL, source);
    ippAddString(collection, IPP_TAG_ZERO, IPP_TAG_KEYWORD, "media-type", NULL, "stationery");
    ippAddCollection(q, IPP_TAG_JOB, "media-col", collection);
    ippDelete(collection);
    // Never retry a submission: a lost response can still mean paper printed.
    ipp_t *r = cupsDoFileRequest(c.http, q, c.resource, file);
    int job = -1;
    if (response_ok(r, error, length)) {
        job = ippGetInteger(ippFindAttribute(r, "job-id", IPP_TAG_INTEGER), 0);
        if (job <= 0) snprintf(error, length, "Printer did not return a job ID; inspect it before retrying.");
    }
    ippDelete(r); httpClose(c.http);
    return job > 0 ? job : -1;
}

int hp_job_state(const char *uri, int job, char *reasons, size_t length) {
    Connection c = connect_printer(uri, reasons, length);
    if (!c.http) return -1;
    ipp_t *q = request(IPP_OP_GET_JOB_ATTRIBUTES, uri);
    ippAddInteger(q, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "job-id", job);
    const char *attrs[] = {"job-state", "job-state-reasons"};
    ippAddStrings(q, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", 2, NULL, attrs);
    ipp_t *r = cupsDoRequest(c.http, q, c.resource);
    int state = -1;
    if (response_ok(r, reasons, length)) {
        state = ippGetInteger(ippFindAttribute(r, "job-state", IPP_TAG_ENUM), 0);
        attribute_text(r, "job-state-reasons", reasons, length);
    }
    ippDelete(r); httpClose(c.http);
    return state;
}

int hp_cancel(const char *uri, int job, char *error, size_t length) {
    Connection c = connect_printer(uri, error, length);
    if (!c.http) return 0;
    ipp_t *q = request(IPP_OP_CANCEL_JOB, uri);
    ippAddInteger(q, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "job-id", job);
    ipp_t *r = cupsDoRequest(c.http, q, c.resource);
    int ok = response_ok(r, error, length);
    ippDelete(r); httpClose(c.http);
    return ok;
}
