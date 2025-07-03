//
//  Copyright (c) Dr. Michael Lauer Information Technology. All rights reserved.
//
#import "helpers.h"
@import os.log;

#define LTSUPPORTAUTOMOTIVE_STRINGS_PATH @"Frameworks/LTSupportAutomotive.framework/LTSupportAutomotive"

void CustomNSLog(NSString *format, ...) {
    va_list argumentList;
    va_start(argumentList, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:argumentList];
    va_end(argumentList);
    
    os_log_t customLog = os_log_create("com.ltsupportautomotive.log", "default");
    os_log(OS_LOG_DEFAULT, "%{public}@", message);
}

NSString* LTStringLookupOrNil( NSString* key )
{
    NSString* value = [[NSBundle bundleForClass:NSClassFromString(@"LTVIN")] localizedStringForKey:key value:nil table:nil];
    return [value isEqualToString:key] ? nil : value;
}

NSString* LTStringLookupWithPlaceholder( NSString* key, NSString* placeholder )
{
    NSString* value = [[NSBundle bundleForClass:NSClassFromString(@"LTVIN")] localizedStringForKey:key value:placeholder table:nil];
    return value;
}

void MyNSLog(const char *file, int lineNumber, const char *functionName, NSString *format, ...)
{
    va_list ap;
    va_start (ap, format);
    if ( ![format hasSuffix:@"\n"] )
    {
        format = [format stringByAppendingString:@"\n"];
    }
    NSString* body = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end (ap);

    NSString* fileName = [[NSString stringWithUTF8String:file] lastPathComponent];
    fprintf( stderr, "%s (%s:%d) %s", functionName, [fileName UTF8String], lineNumber, body.UTF8String );
}

NSString* LTDataToString( NSData* d )
{
    NSString* s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return [[s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
}
