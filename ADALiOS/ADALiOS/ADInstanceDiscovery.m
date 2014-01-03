// Created by Boris Vidolov on 12/27/13.
// Copyright © Microsoft Open Technologies, Inc.
//
// All Rights Reserved
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
// OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
// ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A
// PARTICULAR PURPOSE, MERCHANTABILITY OR NON-INFRINGEMENT.
//
// See the Apache License, Version 2.0 for the specific language
// governing permissions and limitations under the License.
#import "ADALiOS.h"
#import "ADInstanceDiscovery.h"
#import "ADAuthenticationError.h"
#import "HTTPWebRequest.h"
#import "ADAuthenticationError.h"
#import "NSDictionaryExtensions.h"
#import "HTTPWebResponse.h"
#import "ADOAuth2Constants.h"

NSString* const sTrustedAuthority = @"https://login.windows.net";
NSString* const sInstanceDiscoverySuffix = @"common/discovery/instance";
NSString* const sApiVersionKey = @"api-version";
NSString* const sApiVersion = @"1.0";
NSString* const sAuthorizationEndPointKey = @"authorization_endpoint";
NSString* const sCommonAuthorizationEndpoint = @"common/oauth2/authorize";
NSString* const sTenantDiscoveryEndpoint = @"tenant_discovery_endpoint";

NSString* const sValidationServerError = @"The authority validation server returned an error: %@.";

@implementation ADInstanceDiscovery

-(id) init
{
    [super doesNotRecognizeSelector:_cmd];//Throws an exception.
    return nil;
}

-(id) initInternal
{
    self = [super init];
    if (self)
    {
        mValidatedAuthorities = [NSMutableSet setWithObject:sTrustedAuthority];
    }
    
    return self;
}

/*! The getter of the public "validatedAuthorities" property. */
- (NSSet*) getValidatedAuthorities
{
    API_ENTRY;
    NSSet* copy;
    @synchronized (self)
    {
        copy = [NSSet setWithSet:mValidatedAuthorities];
    }
    return copy;
}

+(ADInstanceDiscovery*) sharedInstance
{
    API_ENTRY;
    @synchronized (self)
    {
        static ADInstanceDiscovery* instance;
        if (!instance)
        {
            instance = [[ADInstanceDiscovery alloc] initInternal];
        }
        return instance;
    }
}

/*! Extracts the base URL host, e.g. if the authority is
 "https://login.windows.net/mytenant.com/oauth2/authorize", the host will be
 "https://login.windows.net". Returns nil and reaises an error if the protocol
 is not https or the authority is not a valid URL.*/
-(NSString*) extractHost: (NSString*) authority
                   error: (ADAuthenticationError* __autoreleasing *) error
{
    NSURL* fullUrl = [NSURL URLWithString:authority.lowercaseString];
    if (!fullUrl || ![fullUrl.scheme isEqualToString:@"https"])
    {
        ADAuthenticationError* adError = [ADAuthenticationError errorFromArgument:authority argumentName:@"authority"];
        if (error)
        {
            *error = adError;
        }
        return nil;//Invalid URL
    }

    return [NSString stringWithFormat:@"https://%@", fullUrl.host];
}

-(void) validateAuthority: (NSString*) authority
          completionBlock: (ADDiscoveryCallback) completionBlock
{
    API_ENTRY;
    THROW_ON_NIL_ARGUMENT(completionBlock);
    
    NSString* message = [NSString stringWithFormat:@"Attempting to validate the authority: %@", authority];
    AD_LOG_VERBOSE(@"Instance discovery", message);
    
    ADAuthenticationError* error;
    NSString* authorityHost = [self extractHost:authority error:&error];
    if (error)
    {
        completionBlock(NO, error);
        return;
    }
    
    //Cache poll:
    if ([self isAuthorityValidated:authorityHost])
    {
        completionBlock(YES, nil);
        return;
    }

    //Nothing in the cache, ask the server:
    [self requestValidationOfAuthority:authority
                                  host:authorityHost
                      trustedAuthority:sTrustedAuthority
                       completionBlock:completionBlock];
}

//Checks the cache for previously validated authority.
//Note that the authority host should be normalized: no ending "/" and lowercase.
-(BOOL) isAuthorityValidated: (NSString*) authorityHost
{
    THROW_ON_NIL_EMPTY_ARGUMENT(authorityHost);
    
    BOOL validated;
    @synchronized(self)
    {
        validated = [mValidatedAuthorities containsObject:authorityHost];
    }
    
    NSString* message = [NSString stringWithFormat:@"Checking cache for '%@'. Result: %d", authorityHost, validated];
    AD_LOG_VERBOSE(@"Authority Validation Cache", message);
    return validated;
}

//Note that the authority host should be normalized: no ending "/" and lowercase.
-(void) setAuthorityValidation: (NSString*) authorityHost
{
    THROW_ON_NIL_EMPTY_ARGUMENT(authorityHost);
    
    @synchronized(self)
    {
        [mValidatedAuthorities addObject:authorityHost];
    }
    
    NSString* message = [NSString stringWithFormat:@"Setting validation set to YES for authority '%@'", authorityHost];
    AD_LOG_VERBOSE(@"Authority Validation Cache", message);
}

//Sends authority validation to the trustedAuthority by leveraging the instance discovery endpoint
//If the authority is known, the server will set the "tenant_discovery_endpoint" parameter in the response.
-(void) requestValidationOfAuthority: (NSString*) authority
                                host: (NSString*) authorityHost
                    trustedAuthority: (NSString*) trustedAuthority
                     completionBlock: (ADDiscoveryCallback) completionBlock
{
    THROW_ON_NIL_ARGUMENT(completionBlock);
    
    //All attempts to complete are done. Now try to validate the authorization ednpoint:
    NSString* authorizationEndpoint = [authority stringByAppendingString:OAUTH2_AUTHORIZE_SUFFIX];
    
    NSMutableDictionary *request_data = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                         sApiVersion, sApiVersionKey,
                                         authorizationEndpoint, sAuthorizationEndPointKey,
                                         nil];
    
    NSString* endPoint = [NSString stringWithFormat:@"%@/%@?%@", trustedAuthority, sInstanceDiscoverySuffix, [request_data URLFormEncode]];

    AD_LOG_VERBOSE(@"Authority Validation Request", endPoint);
    HTTPWebRequest *webRequest = [[HTTPWebRequest alloc] initWithURL:[NSURL URLWithString:endPoint]];
    
    webRequest.method = HTTPGet;
    [webRequest.headers setObject:@"application/json" forKey:@"Accept"];
    [webRequest.headers setObject:@"application/x-www-form-urlencoded" forKey:@"Content-Type"];
    
    [webRequest send:^( NSError *error, HTTPWebResponse *webResponse )
    {
        // Request completion callback
        NSDictionary *response = nil;
        
        BOOL verified = NO;
        ADAuthenticationError* adError = nil;
        if ( error == nil )
        {
            switch (webResponse.statusCode)
            {
                case 200:
                case 400:
                case 401:
                {
                    NSError   *jsonError  = nil;
                    id         jsonObject = [NSJSONSerialization JSONObjectWithData:webResponse.body options:0 error:&jsonError];
                    
                    if ( nil != jsonObject && [jsonObject isKindOfClass:[NSDictionary class]] )
                    {
                        // Load the response
                        response = (NSDictionary *)jsonObject;
                        AD_LOG_VERBOSE(@"Discovery response", response.description);
                        verified = ![NSString isStringNilOrBlank:[response objectForKey:sTenantDiscoveryEndpoint]];
                        if (verified)
                        {
                            [self setAuthorityValidation:authorityHost];
                        }
                        else
                        {
                            //First check for explicit OAuth2 protocol error:
                            NSString* serverOAuth2Error = [response objectForKey:OAUTH2_ERROR];
                            NSString* errorDetails = [response objectForKey:OAUTH2_ERROR_DESCRIPTION];
                            // Error response from the server
                            adError = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_AUTHORITY_VALIDATION
                                                                             protocolCode:serverOAuth2Error
                                                                             errorDetails:(errorDetails) ? errorDetails : [NSString stringWithFormat:sValidationServerError, serverOAuth2Error]];

                        }
                    }
                    else
                    {
                        if (jsonError)
                        {
                            adError = [ADAuthenticationError errorFromNSError:jsonError errorDetails:jsonError.localizedDescription];
                        }
                        else
                        {
                            NSString* errorMessage = [NSString stringWithFormat:@"Unexpected object type: %@", [jsonObject class]];
                            adError = [ADAuthenticationError unexpectedInternalError:errorMessage];
                        }
                    }
                }
                    break;
                default:
                {
                    // Request failure
                    NSString* logMessage = [NSString stringWithFormat:@"Server HTTP Status %ld", (long)webResponse.statusCode];
                    NSString* errorData = [NSString stringWithFormat:@"Server HTTP Response %@", [[NSString alloc] initWithData:webResponse.body encoding:NSUTF8StringEncoding]];
                    AD_LOG_WARN(logMessage, errorData);
                    adError = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_AUTHORITY_VALIDATION protocolCode:nil errorDetails:errorData];
                }
            }
        }
        else
        {
            AD_LOG_WARN(@"System error while making request.", error.description);
            // System error
            adError = [ADAuthenticationError errorFromNSError:error errorDetails:error.localizedDescription];
        }
        
        completionBlock( verified, adError );
    }];
}

+(NSString*) canonicalizeAuthority: (NSString*) authority
{
    if ([NSString isStringNilOrBlank:authority])
    {
        return nil;
    }
    
    NSString* trimmedAuthority = [[authority trimmedString] lowercaseString];
    //Start with the trailing slash to ensure that the function covers "<authority>/authorize/" case.
    if ( [trimmedAuthority hasSuffix:@"/" ] )//Remove trailing slash
    {
        trimmedAuthority = [trimmedAuthority substringToIndex:trimmedAuthority.length - 1];
    }
    
    NSURL* url = [NSURL URLWithString:trimmedAuthority];
    if (!url)
    {
        NSString* message = [NSString stringWithFormat:@"Authority %@", authority];
        AD_LOG_WARN(@"The authority is not a valid URL", message);
        return nil;
    }
    NSString* scheme = url.scheme;
    if (![scheme isEqualToString:@"https"])
    {
        NSString* message = [NSString stringWithFormat:@"Authority %@", authority];
        AD_LOG_WARN(@"Non HTTPS protocol for the authority", message);
        return nil;
    }
    
    // Final step is trimming any trailing /authorize or /token from the URL
    // to get to the base URL for the authorization server. After that, we
    // append either /authorize or /token dependent on the request that
    // is being made to the server.
    if ( [trimmedAuthority hasSuffix:OAUTH2_AUTHORIZE_SUFFIX] )
    {
        trimmedAuthority = [trimmedAuthority substringToIndex:trimmedAuthority.length - OAUTH2_AUTHORIZE_SUFFIX.length];
    }
    else if ( [trimmedAuthority hasSuffix:OAUTH2_TOKEN_SUFFIX] )
    {
        trimmedAuthority = [trimmedAuthority substringToIndex:trimmedAuthority.length - OAUTH2_TOKEN_SUFFIX.length];
    }
    
    return trimmedAuthority;
}

@end