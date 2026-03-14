#include "notify_bridge.h"
#include <notify.h>

void post_notification(const char *name) {
    notify_post(name);
}
