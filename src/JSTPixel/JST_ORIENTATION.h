#ifndef JST_ORIENTATION_h
#define JST_ORIENTATION_h

#import <stdint.h>

typedef enum : uint8_t {
    JST_ORIENTATION_HOME_ON_BOTTOM = 0,  /* No changes */
    JST_ORIENTATION_HOME_ON_RIGHT,       /* Turn left, counterclockwise 90 degree */
    JST_ORIENTATION_HOME_ON_LEFT,        /* Turn right, clockwise 90 degree */
    JST_ORIENTATION_HOME_ON_TOP,         /* 180 degree */
} JST_ORIENTATION;

#endif /* JST_ORIENTATION_h */

