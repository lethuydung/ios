//
//  Messaging.m
//  OwnTracks
//
//  Created by Christoph Krey on 20.06.15.
//  Copyright (c) 2015 OwnTracks. All rights reserved.
//

#import "Messaging.h"
#import "Message+Create.h"
#import "CoreData.h"
#import "OwnTracksAppDelegate.h"
#import "Settings.h"
#import "AlertView.h"
#import <objc-geohash/GeoHash.h>
#import <Fabric/Fabric.h>
#import <Crashlytics/Crashlytics.h>
#import <CocoaLumberjack/CocoaLumberjack.h>

#define GEOHASH_LEN_MIN 3
#define GEOHASH_LEN_MAX 6

#define GEOHASH_PRE @"msg/"
#define GEOHASH_SUF @"/msg"
#define GEOHASH_TYPE @"msg"
#define GEOHASH_KEY @"lastGeoHash"

@interface Messaging()
@property (strong, nonatomic) NSString *oldGeoHash;
@end

@implementation Messaging
static Messaging *theInstance = nil;

+ (Messaging *)sharedInstance {
    if (theInstance == nil) {
        theInstance = [[Messaging alloc] init];
    }
    return theInstance;
}

static const DDLogLevel ddLogLevel = DDLogLevelError;

- (instancetype)init {
    self = [super init];
    DDLogVerbose(@"Messages ddLogLevel %lu", (unsigned long)ddLogLevel);
    self.lastGeoHash = [Settings stringForKey:GEOHASH_KEY];
    self.oldGeoHash = @"";
    self.messages = [NSNumber numberWithUnsignedInteger:0];
    return self;
}

- (void)updateCounter:(NSManagedObjectContext *)context {
    self.messages = [NSNumber numberWithUnsignedInteger:[Message expireMessages:context]];
}

- (void)reset:(NSManagedObjectContext *)context {
    NSString *geoHash = self.lastGeoHash;
    self.oldGeoHash = self.lastGeoHash;
    self.lastGeoHash = @"";
    [self manageSubscriptions:context];
    if ([Settings boolForKey:SETTINGS_MESSAGING]) {
        [Message removeMessages:context];
        self.oldGeoHash = @"";
        self.lastGeoHash = geoHash;
        [self manageSubscriptions:context];
    }
    self.messages = [NSNumber numberWithUnsignedInteger:[Message expireMessages:context]];
}

- (void)manageSubscriptions:(NSManagedObjectContext *)context {
    OwnTracksAppDelegate *delegate = (OwnTracksAppDelegate *)[[UIApplication sharedApplication] delegate];
    NSMutableDictionary *subscriptions = [NSMutableDictionary dictionaryWithDictionary:
                                          delegate.connectionIn.variableSubscriptions];
    
    NSString *systemTopic = [NSString stringWithFormat:@"%@system", GEOHASH_PRE];
    [subscriptions setObject:[NSNumber numberWithInt:MQTTQosLevelExactlyOnce] forKey:systemTopic];
    
    NSString *ownTopic = [NSString stringWithFormat:@"%@%@",
                          [Settings theGeneralTopic], GEOHASH_SUF];
    [subscriptions setObject:[NSNumber numberWithInt:MQTTQosLevelExactlyOnce] forKey:ownTopic];
    
    for (int i = GEOHASH_LEN_MIN - 1; i < self.oldGeoHash.length; i++) {
        NSString *old = [self.oldGeoHash substringWithRange:NSMakeRange(i, 1)];
        NSString *last;
        if (i < self.lastGeoHash.length) {
            last = [self.lastGeoHash substringWithRange:NSMakeRange(i, 1)];
        } else {
            last = @"";
        }
        if (![old isEqualToString:last]) {
            NSString *topic = [NSString stringWithFormat:@"%@+/%@",
                               GEOHASH_PRE,
                               [self.oldGeoHash substringToIndex:i + 1]];
            [subscriptions removeObjectForKey:topic];
            [Message removeMessages:[self.oldGeoHash substringToIndex:i + 1] context:context];
        }
    }
    for (int i = GEOHASH_LEN_MIN - 1; i < self.lastGeoHash.length; i++) {
        NSString *last = [self.lastGeoHash substringWithRange:NSMakeRange(i, 1)];
        NSString *old;
        if (i < self.oldGeoHash.length) {
            old = [self.oldGeoHash substringWithRange:NSMakeRange(i, 1)];
        } else {
            old = @"";
        }
        if (![last isEqualToString:old]) {
            NSString *topic = [NSString stringWithFormat:@"%@+/%@",
                               GEOHASH_PRE,
                               [self.lastGeoHash substringToIndex:i + 1]];
            [subscriptions setValue:[NSNumber numberWithInt:MQTTQosLevelExactlyOnce] forKey:topic];
        }
    }
    delegate.connectionIn.variableSubscriptions = subscriptions;
    
    NSError *error = nil;
    if (![context save:&error]) {
        DDLogError(@"Unresolved error %@, %@", error, [error userInfo]);
        [[Crashlytics sharedInstance] setObjectValue:@"manageSubscriptions" forKey:@"CrashType"];
        [[Crashlytics sharedInstance] crash];
    }
}

- (void)newLocation:(double)latitude longitude:(double)longitude context:(NSManagedObjectContext *)context {
    NSString *geoHash = [GeoHash hashForLatitude:latitude
                                       longitude:longitude
                                          length:GEOHASH_LEN_MAX];
    DDLogVerbose(@"geoHash %@", geoHash);
    
    if (![self.lastGeoHash isEqualToString:geoHash]) {
        self.oldGeoHash = self.lastGeoHash;
        [Settings setString: geoHash forKey:GEOHASH_KEY];
        self.lastGeoHash = geoHash;
        DDLogVerbose(@"geoHash %@", geoHash);
        
        [self manageSubscriptions:context];
    } else {
        self.lastGeoHash = self.lastGeoHash;
    }
    [CoreData saveContext:context];
    self.messages = [NSNumber numberWithUnsignedInteger:[Message expireMessages:context]];
    [CoreData saveContext:context];
}

- (BOOL)processMessage:(NSString *)topic
                  data:(NSData *)data
              retained:(BOOL)retained
               context:(NSManagedObjectContext *)context {
    if ([topic hasPrefix:GEOHASH_PRE]) {
        NSArray *components = [topic componentsSeparatedByString:@"/"];
        NSError *error;
        NSDictionary *dictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (dictionary) {
            NSString *type = dictionary[@"_type"];
            if ([type isEqualToString:GEOHASH_TYPE]) {
                NSString *desc = dictionary[@"desc"];
                NSString *title = dictionary[@"title"];
                NSString *url = dictionary[@"url"];
                NSString *iconurl = dictionary[@"iconurl"];
                NSString *icon = dictionary[@"icon"];
                NSInteger prio = [dictionary[@"prio"] intValue];
                NSUInteger ttl = [dictionary[@"ttl"] unsignedIntegerValue];
                NSDate *timestamp = [NSDate dateWithTimeIntervalSince1970:[dictionary[@"tst"] doubleValue]];
                
                if (components.count == 3) {
                    NSString *geoHash = components[2];
                    if ([self.lastGeoHash hasPrefix:geoHash]) {
                        [context performBlock:^{
                            [Message messageWithTopic:topic
                                                 icon:icon
                                                 prio:prio
                                            timestamp:timestamp
                                                  ttl:ttl
                                                title:title
                                                 desc:desc
                                                  url:url
                                              iconurl:iconurl
                               inManagedObjectContext:context];
                            self.messages = [NSNumber numberWithUnsignedInteger:[Message expireMessages:context]];
                            [CoreData saveContext:context];
                        }];
                    } else {
                        [context performBlock:^{
                            DDLogVerbose(@"remove topic %@", topic);
                            [Message removeMessages:topic context:context];
                            self.messages = [NSNumber numberWithUnsignedInteger:[Message expireMessages:context]];
                            [CoreData saveContext:context];
                            OwnTracksAppDelegate *delegate = (OwnTracksAppDelegate *)[[UIApplication sharedApplication] delegate];
                            [delegate.connectionIn unsubscribeFromTopic:topic];
                        }];
                        return TRUE;
                    }
                } else if (components.count == 2) {
                    NSString *secondComponent = components[1];
                    if ([secondComponent isEqualToString:@"system"]) {
                        [context performBlock:^{
                            [Message messageWithTopic:topic
                                                 icon:icon
                                                 prio:prio
                                            timestamp:timestamp
                                                  ttl:ttl
                                                title:title
                                                 desc:desc
                                                  url:url
                                              iconurl:iconurl
                               inManagedObjectContext:context];
                            self.messages = [NSNumber numberWithUnsignedInteger:[Message expireMessages:context]];
                            [CoreData saveContext:context];
                        }];
                        
                    }
                } else {
                    DDLogVerbose(@"illegal msg topic %@", topic);
                    return FALSE;
                }
            } else {
                DDLogVerbose(@"unknown type %@", type);
                return FALSE;
            }
        } else {
            DDLogVerbose(@"illegal json %@ %@ %@", error.localizedDescription, error.userInfo, data.description);
            return FALSE;
        }
    } else if ([topic isEqualToString:[NSString stringWithFormat:@"%@%@",
                                       [Settings theGeneralTopic],
                                       GEOHASH_SUF]]) {
        NSError *error;
        NSDictionary *dictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (dictionary) {
            NSString *type = dictionary[@"_type"];
            if ([type isEqualToString:GEOHASH_TYPE]) {
                NSString *desc = dictionary[@"desc"];
                NSString *title = dictionary[@"title"];
                NSString *url = dictionary[@"url"];
                NSString *iconurl = dictionary[@"iconurl"];
                NSString *icon = dictionary[@"icon"];
                NSInteger prio = [dictionary[@"prio"] intValue];
                NSUInteger ttl = [dictionary[@"ttl"] unsignedIntegerValue];
                NSDate *timestamp = [NSDate dateWithTimeIntervalSince1970:[dictionary[@"tst"] doubleValue]];
                
                
                [context performBlock:^{
                    [Message messageWithTopic:topic
                                         icon:icon
                                         prio:prio
                                    timestamp:timestamp
                                          ttl:ttl
                                        title:title
                                         desc:desc
                                          url:url
                                      iconurl:iconurl
                       inManagedObjectContext:context];
                    self.messages = [NSNumber numberWithUnsignedInteger:[Message expireMessages:context]];
                    [CoreData saveContext:context];
                }];
            } else {
                DDLogVerbose(@"unknown type %@", type);
                return FALSE;
            }
        } else {
            DDLogVerbose(@"illegal json %@ %@ %@", error.localizedDescription, error.userInfo, data.description);
            return FALSE;
        }
    } else {
        return FALSE;
    }

    UILocalNotification *notification = [[UILocalNotification alloc] init];
    notification.alertBody = @"New message arrived";
    notification.userInfo = @{@"notify": @"msg"};
    notification.fireDate = [NSDate dateWithTimeIntervalSinceNow:1.0];
    [[UIApplication sharedApplication] scheduleLocalNotification:notification];
    
    return TRUE;
}

@end
