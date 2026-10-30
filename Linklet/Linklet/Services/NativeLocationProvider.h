#import <WebKit/WebKit.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN
BOOL LKInstallNativeLocationProvider(WKProcessPool *pool);
#if DEBUG
void LKUseTestLocation(WKProcessPool *pool, CLLocation *location);
BOOL LKLocationProviderIsUpdating(WKProcessPool *pool);
#endif
NS_ASSUME_NONNULL_END
