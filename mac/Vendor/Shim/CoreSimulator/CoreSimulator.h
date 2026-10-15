#import <Foundation/Foundation.h>

// Opaque stand-ins for CoreSimulator's private classes. FBSimulatorControl's
// Swift interface names these types; SimStream never touches them directly.
@interface SimDevice : NSObject
@end
@interface SimDeviceSet : NSObject
@end
@interface SimDeviceType : NSObject
@end
@interface SimRuntime : NSObject
@end
