#ifndef QS_KEYBOARD_ESCAPE_POLICY_H
#define QS_KEYBOARD_ESCAPE_POLICY_H
#include <stdbool.h>
#include <math.h>

typedef struct {
    unsigned int presses;
    double lastRelease;
    bool escapeDown;
} QSEscapePolicy;

// Count distinct press/release pairs, never a held key or synthetic duplicate key-downs.
static inline bool QSConsumeEmergencyEscape(QSEscapePolicy *state, bool keyDown,
                                            unsigned int keyCode, bool autorepeat, double now) {
    if (!isfinite(now) || now < 0) { *state = (QSEscapePolicy){0}; return false; }
    if (keyCode != 53) {
        if (keyDown) *state = (QSEscapePolicy){0};
        return false;
    }
    if (keyDown) {
        if (!autorepeat) state->escapeDown = true;
        return false;
    }
    if (!state->escapeDown) return false;
    state->escapeDown = false;
    state->presses = state->presses && now >= state->lastRelease && now - state->lastRelease <= 1.2
        ? state->presses + 1 : 1;
    state->lastRelease = now;
    return state->presses >= 3;
}
#endif
