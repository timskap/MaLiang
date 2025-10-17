#ifdef __OBJC__
#import <UIKit/UIKit.h>
#else
#ifndef FOUNDATION_EXPORT
#if defined(__cplusplus)
#define FOUNDATION_EXPORT extern "C"
#else
#define FOUNDATION_EXPORT extern
#endif
#endif
#endif

#import "Zip.h"

// Include minizip headers directly
#import "minizip/unzip.h"
#import "minizip/zip.h"

FOUNDATION_EXPORT double ZipVersionNumber;
FOUNDATION_EXPORT const unsigned char ZipVersionString[];

