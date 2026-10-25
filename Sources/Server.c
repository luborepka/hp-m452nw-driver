#include "PrinterBridge.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <string.h>

#define MAX_BODY 75065536
typedef struct { http_t *http; size_t read; } Input;
static ssize_t read_bounded(void *context, ipp_uchar_t *buffer, size_t length) {
    Input *input = context;
    if (input->read >= MAX_BODY) {
        char extra;
        return httpRead2(input->http, &extra, 1) == 0 ? 0 : -1;
    }
    if (length > MAX_BODY - input->read) length = MAX_BODY - input->read;
    ssize_t count = httpRead2(input->http, (char *)buffer, length);
    if (count > 0) input->read += (size_t)count;
    return count;
}

int hp_listen(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0), yes = 1;
    if (fd < 0) return -1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&address, sizeof address) || listen(fd, 8)) {
        close(fd); return -1;
    }
    return fd;
}

// libcups handles HTTP framing, chunking and IPP decoding. Document bytes are
// streamed to disk instead of buffering the whole print job in memory.
ipp_t *hp_receive(http_t *http, const char *document) {
    char path[1024];
    httpSetTimeout(http, 30, NULL, NULL);
    if (httpReadRequest(http, path, sizeof path) != HTTP_STATE_POST) return NULL;
    http_status_t status;
    do { status = httpUpdate(http); } while (status == HTTP_STATUS_CONTINUE);
    if (status != HTTP_STATUS_OK || (strcmp(path, "/ipp/print") && strncmp(path, "/ipp/print/jobs/", 16)) ||
        strcmp(httpGetField(http, HTTP_FIELD_CONTENT_TYPE), "application/ipp") ||
        httpGetLength2(http) > MAX_BODY) return NULL;
    if (httpGetExpect(http) == HTTP_STATUS_CONTINUE)
        httpWriteResponse(http, HTTP_STATUS_CONTINUE);
    Input input = {http, 0};
    ipp_t *request = ippNew();
    if (ippReadIO(&input, read_bounded, 1, NULL, request) != IPP_STATE_DATA ||
        ippLength(request) > 65536) { ippDelete(request); return NULL; }
    if (ippGetOperation(request) != IPP_OP_PRINT_JOB && ippGetOperation(request) != IPP_OP_SEND_DOCUMENT) {
        unsigned char extra;
        if (read_bounded(&input, &extra, 1) != 0) { ippDelete(request); return NULL; }
        return request;
    }
    int fd = open(document, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) { ippDelete(request); return NULL; }
    unsigned char buffer[65536]; ssize_t count;
    int ok = 1;
    while ((count = read_bounded(&input, buffer, sizeof buffer)) > 0) {
        size_t offset = 0;
        while (offset < (size_t)count) {
            ssize_t written = write(fd, buffer + offset, (size_t)count - offset);
            if (written <= 0) { ok = 0; break; }
            offset += (size_t)written;
        }
        if (!ok) break;
    }
    if (count < 0 || fsync(fd)) ok = 0;
    close(fd);
    if (!ok) { ippDelete(request); unlink(document); return NULL; }
    return request;
}

void hp_reply(http_t *http, ipp_t *response) {
    httpClearFields(http);
    httpSetKeepAlive(http, HTTP_KEEPALIVE_OFF);
    httpSetField(http, HTTP_FIELD_CONTENT_TYPE, "application/ipp");
    httpSetLength(http, ippLength(response));
    if (httpWriteResponse(http, HTTP_STATUS_OK) == 0)
        ippWrite(http, response);
    httpFlushWrite(http);
}
