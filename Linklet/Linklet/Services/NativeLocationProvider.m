#import "NativeLocationProvider.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#include <stdbool.h>

// macOS WebKit exposes site consent publicly, but requires an embedder-supplied
// coordinate provider. Keep its C SPI ABI in this guarded adapter; Core Location
// and the web page's geolocation API retain their native behavior.
typedef const void *LKGeoRef;
typedef struct { int version; const void *clientInfo; } LKProviderBase;
typedef struct {
    LKProviderBase base;
    void (*start)(LKGeoRef, const void *);
    void (*stop)(LKGeoRef, const void *);
    void (*accuracy)(LKGeoRef, bool, const void *);
} LKProviderV1;

static LKGeoRef (*getManager)(LKGeoRef);
static void (*setProvider)(LKGeoRef, const LKProviderBase *);
static LKGeoRef (*createPosition)(double, double, double, double);
static void (*positionChanged)(LKGeoRef, LKGeoRef);
static void (*positionFailed)(LKGeoRef);
static void (*releaseObject)(LKGeoRef);
static const char providerKey;

@interface LKNativeLocationProvider : NSObject <CLLocationManagerDelegate>
@property(nonatomic) LKGeoRef manager;
@property(nonatomic, strong) CLLocationManager *source;
@property(nonatomic) BOOL updating;
@property(nonatomic) BOOL highAccuracy;
#if DEBUG
@property(nonatomic, strong) CLLocation *testLocation;
#endif
- (void)start;
- (void)stop;
- (void)deliver:(CLLocation *)location;
@end

static void startLocation(LKGeoRef manager, const void *info) {
    [(__bridge LKNativeLocationProvider *)info start];
}
static void stopLocation(LKGeoRef manager, const void *info) {
    [(__bridge LKNativeLocationProvider *)info stop];
}
static void setAccuracy(LKGeoRef manager, bool highAccuracy, const void *info) {
    LKNativeLocationProvider *provider = (__bridge LKNativeLocationProvider *)info;
    provider.highAccuracy = highAccuracy;
    provider.source.desiredAccuracy = highAccuracy ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters;
}

@implementation LKNativeLocationProvider
- (void)start {
    if (_updating) return;
    _updating = YES;
#if DEBUG
    if (_testLocation) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (self.updating) [self deliver:self.testLocation]; });
        return;
    }
#endif
    if (!_source) {
        _source = [[CLLocationManager alloc] init];
        _source.delegate = self;
    }
    _source.desiredAccuracy = _highAccuracy ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters;
    [self locationManagerDidChangeAuthorization:_source];
}
- (void)stop {
    _updating = NO;
    [_source stopUpdatingLocation];
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (!_updating) return;
    switch (manager.authorizationStatus) {
        case kCLAuthorizationStatusNotDetermined:
            [manager requestWhenInUseAuthorization];
            break;
        case kCLAuthorizationStatusAuthorizedAlways:
            [manager startUpdatingLocation];
            break;
        case kCLAuthorizationStatusDenied:
        case kCLAuthorizationStatusRestricted:
            [manager stopUpdatingLocation];
            positionFailed(_manager);
            break;
    }
}
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (_updating && locations.lastObject) [self deliver:locations.lastObject];
}
- (void)deliver:(CLLocation *)location {
    if (!_updating || !location || location.horizontalAccuracy < 0 || !CLLocationCoordinate2DIsValid(location.coordinate)) return;
    LKGeoRef position = createPosition(location.timestamp.timeIntervalSince1970,
                                      location.coordinate.latitude, location.coordinate.longitude, location.horizontalAccuracy);
    if (position) { positionChanged(_manager, position); releaseObject(position); }
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    // A temporarily unavailable fix is retried by Core Location; do not make
    // maps give up before the next good fix arrives.
    if (!_updating || ([error.domain isEqualToString:kCLErrorDomain] && error.code == kCLErrorLocationUnknown)) return;
    positionFailed(_manager);
}
- (void)dealloc {
    _source.delegate = nil;
    [_source stopUpdatingLocation];
}
@end

BOOL LKInstallNativeLocationProvider(WKProcessPool *pool) {
    if (objc_getAssociatedObject(pool, &providerKey)) return YES;
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getManager = dlsym(RTLD_DEFAULT, "WKContextGetGeolocationManager");
        setProvider = dlsym(RTLD_DEFAULT, "WKGeolocationManagerSetProvider");
        createPosition = dlsym(RTLD_DEFAULT, "WKGeolocationPositionCreate");
        positionChanged = dlsym(RTLD_DEFAULT, "WKGeolocationManagerProviderDidChangePosition");
        positionFailed = dlsym(RTLD_DEFAULT, "WKGeolocationManagerProviderDidFailToDeterminePosition");
        releaseObject = dlsym(RTLD_DEFAULT, "WKRelease");
        available = getManager && setProvider && createPosition && positionChanged && positionFailed && releaseObject;
    });
    if (!available) return NO;
    LKGeoRef manager = getManager((__bridge LKGeoRef)pool);
    if (!manager) return NO;
    LKNativeLocationProvider *provider = [[LKNativeLocationProvider alloc] init];
    provider.manager = manager;
    // The pool owns the adapter for as long as WebKit may call clientInfo.
    objc_setAssociatedObject(pool, &providerKey, provider, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LKProviderV1 callbacks = { { 1, (__bridge const void *)provider }, startLocation, stopLocation, setAccuracy };
    setProvider(manager, &callbacks.base);
    return YES;
}

#if DEBUG
void LKUseTestLocation(WKProcessPool *pool, CLLocation *location) {
    if (!LKInstallNativeLocationProvider(pool)) return;
    LKNativeLocationProvider *provider = objc_getAssociatedObject(pool, &providerKey);
    [provider stop];
    provider.source.delegate = nil;
    provider.source = nil;
    provider.testLocation = location;
}
BOOL LKLocationProviderIsUpdating(WKProcessPool *pool) {
    return [(LKNativeLocationProvider *)objc_getAssociatedObject(pool, &providerKey) updating];
}
#endif
