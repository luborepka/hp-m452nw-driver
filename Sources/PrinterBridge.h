#ifndef PRINTER_BRIDGE_H
#define PRINTER_BRIDGE_H
#include <stddef.h>
#include <cups/cups.h>
#include <cups/http.h>
#include <cups/ipp.h>
typedef struct {
    char model[256];
    char reasons[512];
    int state;
    int accepting;
    int pdf;
    int tray1;
    int tray1_loaded; /* -1 unknown, 0 empty, 1 paper present */
} HPPrinterInfo;
int hp_probe(const char *uri, HPPrinterInfo *info, char *error, size_t length);
int hp_submit(const char *uri, const char *file, const char *title,
              const char *media, const char *source, const char *color,
              char *error, size_t length);
int hp_job_state(const char *uri, int job, char *reasons, size_t length);
int hp_cancel(const char *uri, int job, char *error, size_t length);
int hp_listen(int port);
ipp_t *hp_receive(http_t *http, const char *document);
void hp_reply(http_t *http, ipp_t *response);
#endif
