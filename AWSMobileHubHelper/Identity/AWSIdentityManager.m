//
//  AWSIdentityManager.m
//
// Copyright 2016 Amazon.com, Inc. or its affiliates (Amazon). All Rights Reserved.
//
// Code generated by AWS Mobile Hub. Amazon gives unlimited permission to
// copy, distribute and modify it.
//

#import "AWSIdentityManager.h"
#import "AWSSignInProvider.h"
#import "AWSFacebookSignInProvider.h"
#import "AWSGoogleSignInProvider.h"
#import "FBSDKLoginManagerLoginResult.h"

NSString *const AWSIdentityManagerDidSignInNotification = @"com.amazonaws.AWSIdentityManager.AWSIdentityManagerDidSignInNotification";
NSString *const AWSIdentityManagerDidSignOutNotification = @"com.amazonaws.AWSIdentityManager.AWSIdentityManagerDidSignOutNotification";

typedef void (^AWSIdentityManagerCompletionBlock)( FBSDKLoginManagerLoginResult * result, NSError *error);

@interface AWSIdentityManager()
    
    @property (nonatomic, strong) AWSCognitoCredentialsProvider *credentialsProvider;
    @property (atomic, copy) AWSIdentityManagerCompletionBlock completionHandler;
    
    @property (nonatomic, strong) id<AWSSignInProvider> currentSignInProvider;
    
    @end

@implementation AWSIdentityManager

NSDictionary<NSString *, NSString *> *loginCache;
NSDictionary<NSString *, id<AWSSignInProvider>> *signInProviderCache; // keep track of all active AWSSignInProviders
BOOL mergingIdentityProviderManager;
BOOL multiAccountIdentityProviderManager;



static NSString *const AWSInfoIdentityManager = @"IdentityManager";
static NSString *const AWSInfoRoot = @"AWS";
static NSString *const AWSInfoMobileHub = @"MobileHub";
static NSString *const AWSInfoProjectClientId = @"ProjectClientId";
static NSString *const AWSInfoAllowIdentityMerging = @"Allow Identity Merging";
static NSString *const AWSInfoAllowSimultaneousActiveAccounts = @"Allow Simultaneous Active Accounts";

+ (instancetype)defaultIdentityManager {
    static AWSIdentityManager *_defaultIdentityManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        AWSServiceInfo *serviceInfo = [[AWSInfo defaultAWSInfo] defaultServiceInfo:AWSInfoIdentityManager];
        
        if (!serviceInfo) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                           reason:@"The service configuration is `nil`. You need to configure `Info.plist` before using this method."
                                         userInfo:nil];
        }
        _defaultIdentityManager = [[AWSIdentityManager alloc] initWithCredentialProvider:serviceInfo];
        loginCache = [[NSDictionary<NSString *, NSString *> alloc] init];
        mergingIdentityProviderManager = [[serviceInfo.infoDictionary valueForKey:AWSInfoAllowIdentityMerging] boolValue];
        multiAccountIdentityProviderManager =  [[serviceInfo.infoDictionary valueForKey:AWSInfoAllowSimultaneousActiveAccounts  ] boolValue];
        signInProviderCache = [[NSDictionary<NSString *, id<AWSSignInProvider>> alloc] init];
    });
    
    return _defaultIdentityManager;
}

- (instancetype)initWithCredentialProvider:(AWSServiceInfo *)serviceInfo {
    if (self = [super init]) {
        [AWSLogger defaultLogger].logLevel = AWSLogLevelVerbose;
        
        self.credentialsProvider = serviceInfo.cognitoCredentialsProvider;
        [self.credentialsProvider setIdentityProviderManagerOnce:self];
        
        // Init the ProjectTemplateId
        NSString *projectTemplateId = [[[AWSInfo defaultAWSInfo].rootInfoDictionary objectForKey:AWSInfoMobileHub] objectForKey:AWSInfoProjectClientId];
        if (!projectTemplateId) {
            projectTemplateId = @"MobileHub HelperFramework";
        }
        [AWSServiceConfiguration addGlobalUserAgentProductToken:projectTemplateId];
    }
    return self;
}

#pragma mark - AWSIdentityProviderManager

- (AWSTask<NSDictionary<NSString *, NSString *> *> *)logins {
    if (!self.currentSignInProvider) {
        return [AWSTask taskWithResult:nil];
    }
    return [[self.currentSignInProvider token] continueWithSuccessBlock:^id _Nullable(AWSTask<NSString *> * _Nonnull task) {
        NSString *token = task.result;
        [self mergeLogins:@{self.currentSignInProvider.identityProviderName : token}];
        return [AWSTask taskWithResult: loginCache];
    }];
}

- (void)mergeLogins:(NSDictionary<NSString *,NSString *> *)logins {
    if (!mergingIdentityProviderManager) {
        loginCache = [logins copy]; // not merging?  replace the cache with what they passed
    } else { // merging, add the new login to the cache
        NSMutableDictionary<NSString *, NSString *> *merge = [[NSMutableDictionary<NSString *, NSString *> alloc] init];
        merge = [loginCache mutableCopy];
        
        for (NSString* key in logins) {
            merge[key] = logins[key];
        }
        loginCache = [merge copy];
    }
}

- (void)dropLogin:(NSString *)key {
    NSMutableDictionary<NSString *, NSString *> *shorterList = [[NSMutableDictionary<NSString *, NSString *> alloc] init];
    shorterList = [loginCache mutableCopy];
    [shorterList removeObjectForKey: key];
    loginCache = [shorterList copy];
}

- (NSArray *)activeProviders {
    return [signInProviderCache allValues];
}
- (void)activateProvider: (id<AWSSignInProvider>)signInProvider {
    NSMutableDictionary<NSString *, id<AWSSignInProvider>> *mergeCache = [[NSMutableDictionary<NSString *, id<AWSSignInProvider>> alloc] init];
    if (multiAccountIdentityProviderManager) {
        mergeCache = [signInProviderCache mutableCopy];
    }
    [mergeCache setValue:signInProvider forKey:[signInProvider identityProviderName ]];
    signInProviderCache = [mergeCache copy];
}
- (void)deactivateProvider: (id<AWSSignInProvider>)signInProvider {
    NSMutableDictionary<NSString *, id<AWSSignInProvider>> *mergeCache = [[NSMutableDictionary<NSString *, id<AWSSignInProvider>> alloc] init];
    mergeCache = [signInProviderCache mutableCopy];
    [mergeCache  removeObjectForKey:[signInProvider identityProviderName ]];
    signInProviderCache = [mergeCache copy];
}


#pragma mark -

- (NSString *)identityId {
    return self.credentialsProvider.identityId;
}

- (BOOL)isLoggedIn {
    return self.currentSignInProvider.isLoggedIn;
}

- (NSURL *)imageURL {
    return self.currentSignInProvider.imageURL;
}

- (NSString *)userName {
    return self.currentSignInProvider.userName;
}

- (NSString *)authenticatedBy {
    if (self.currentSignInProvider == nil ) {
        return @"Guest";
    }
    return [self providerKey: self.currentSignInProvider];
}

- (NSString *)providerKey:(id<AWSSignInProvider>)signInProvider {
    NSString *provider = nil;
    AWSServiceInfo *serviceInfo = [[AWSInfo defaultAWSInfo] defaultServiceInfo:AWSInfoIdentityManager];
    NSDictionary *signInProviderKeyDictionary = [serviceInfo.infoDictionary objectForKey:@"SignInProviderKeyDictionary"];
    provider = [signInProviderKeyDictionary objectForKey:NSStringFromClass([signInProvider class])];
    if (provider) {
        return provider;
    } else {
        return @"SignInProviderKeyDictionary is not configured properly";
    }
}

- (void)wipeAll {
    [self.credentialsProvider clearKeychain];
}


- (void)logoutWithCompletionHandler:(void (^)(id result, NSError *error))completionHandler {
    if ([self.currentSignInProvider isLoggedIn]) {
        // must shrink the logins cache so he can log back in
        [self dropLogin: [self.currentSignInProvider identityProviderName]];
        [self.currentSignInProvider logout];
    }
    [self deactivateProvider: self.currentSignInProvider];
    self.currentSignInProvider = nil;
    // we still have an identityId
    [self wipeAll];
    //before we go get a new identityId, lets see if we are still logged in with another provider
    [self interceptApplication: [UIApplication sharedApplication] didFinishLaunchingWithOptions:nil];
    
    [[self.credentialsProvider getIdentityId] continueWithBlock:^id _Nullable(AWSTask<NSString *> * _Nonnull task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
            [notificationCenter postNotificationName:AWSIdentityManagerDidSignOutNotification
                                              object:[AWSIdentityManager defaultIdentityManager]
                                            userInfo:nil];
            if (task.exception) {
                AWSLogError(@"Fatal exception: [%@]", task.exception);
                kill(getpid(), SIGKILL);
            }
            completionHandler(task.result, task.error);
        });
        return nil;
    }];
}

- (void)loginWithSignInProvider:(id)signInProvider
              completionHandler:(void (^)(id result, NSError *error))completionHandler {
    // modify to allow multiple logins only if Allow Identity Merging is YES in Info.plist
    // Each time loginWithSignInprovider runs the existing sign in provider keeps it's active
    // session indicator in NSUserDefaults.  The current sign in provider is changed but
    // we will return logins for all signin providers with an NSUserDefault key of YES
    // Logout will log out the current sign in provider an resume a session with any
    // remaining ones.
    
    if (!multiAccountIdentityProviderManager  && self.currentSignInProvider) {
        [self logoutWithCompletionHandler:^(FBSDKLoginManagerLoginResult *result, NSError *error) {
            //      [self logoutWithCompletionHandler:^void (id result, NSError *error) {
            if ( error != nil ) {
                NSLog( @"Error from logoutWithCompletionHandler %@", error);
            }
        }];
    }
    if (multiAccountIdentityProviderManager && !mergingIdentityProviderManager) {
        // in this case, we don't want to let the credentials provider retry till he decides
        // to do a getcredentials, instead we wipe and force it.
        // This allows multiple stacked logins without merging
        [self wipeAll];
    }
    self.currentSignInProvider = signInProvider;
    
    self.completionHandler = completionHandler;
    [self.currentSignInProvider login:^(FBSDKLoginManagerLoginResult *result, NSError *error) {
        if ( error != nil ) {
            NSLog( @"Error from login %@, cancelling", error);
            // quick and dirty housekeeping logout
            [self dropLogin: [self.currentSignInProvider identityProviderName]];
            [self deactivateProvider: self.currentSignInProvider];
            self.currentSignInProvider = nil;
            
        }
        self.completionHandler(result,error);
    }];
}

- (void)resumeSessionWithCompletionHandler:(void (^)(id result, NSError *error))completionHandler {
    self.completionHandler = completionHandler;
    
    for (id<AWSSignInProvider> provider  in [self activeProviders]) {
        [provider reloadSession]; // reload each of the providers that have active sessions
        NSLog(@"Reloading provider: %@", [self providerKey:provider ]);
    }
    // Always do completion handler to guarantee credentials and NSNotification
    [self completeLogin];
}

- (void)completeLogin {
    
    if ([[self currentSignInProvider] isLoggedIn]) {// (he didn't hit done, cancel or deny?)
        [self activateProvider: self.currentSignInProvider];
    }
    
    // Force a refresh of credentials to see if we need to merge
    [self.credentialsProvider invalidateCachedTemporaryCredentials];
    
    [[self.credentialsProvider credentials] continueWithBlock:^id _Nullable(AWSTask<AWSCredentials *> * _Nonnull task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.currentSignInProvider) {
                NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
                [notificationCenter postNotificationName:AWSIdentityManagerDidSignInNotification
                                                  object:[AWSIdentityManager defaultIdentityManager]
                                                userInfo:nil];
            }
            if (task.exception) {
                AWSLogError(@"Fatal exception: [%@]", task.exception);
                kill(getpid(), SIGKILL);
            }
            
            // sometimes were are about to "link" an identity (merge) and if it doesn't work
            // if for instance we a linking two identities that both have linked logins in the same provider.
            // In that case, Identity Manager provides the error but switches to the new authentication provider anyway!
            // Instead we need to log out that identity and stick with the one are (it is
            // a failed login, not logging in with another provider.  We could log out the
            // first provider and login the second but if we did that we would need to add a
            // new method (linkAccountWithSignInProvider)".
            
            if (task.error.code == AWSCognitoIdentityErrorResourceConflict || task.error != nil) {
                // any error, and especially cannot merge these identities, should fail the login
                // so log this guy out and find any existing sessions to restart
                // Then go find another active session (there surely is one for "cannot merge" errors)
                [self logoutWithCompletionHandler:^void (id result, NSError *error) {
                    if ( error != nil ) {
                        NSLog( @"Error from logoutWithCompletionHandler %@", error);
                    }
                    self.completionHandler(task.result, task.error); // done deliver result
                }];
            } else {
                self.completionHandler(task.result, task.error);  // no issues
            }
        });
        return nil;
    }];
}

- (BOOL)interceptApplication:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    Class signInProviderClass = nil;
    
    AWSServiceInfo *serviceInfo = [[AWSInfo defaultAWSInfo] defaultServiceInfo:AWSInfoIdentityManager];
    NSDictionary *signInProviderKeyDictionary = [serviceInfo.infoDictionary objectForKey:@"SignInProviderKeyDictionary"];
    
    // loop through the Info.plist AWS->IdentityManager->Default->SignInProviderClass dictionary
    // which contains the class name of the SignInProvider and the NSUserDefaults key,
    // this way, developer and user pools IdP's can maintain a session too (not just
    // Google and Facebook) - Dictionary looks like "AWSGoogleSignInProvider":"Google" etc.
    // if you are supporting merging identities, the current sign in provider will be the last
    // one listed in the dictionary (are dictionaries ordered) with a key in NSUserDefaults.
    for (NSString *key in signInProviderKeyDictionary) {
        if ([[NSUserDefaults standardUserDefaults] objectForKey:[signInProviderKeyDictionary objectForKey:key]]) {
            signInProviderClass = NSClassFromString(key);
            
            self.currentSignInProvider = [signInProviderClass sharedInstance];
            if (signInProviderClass && !self.currentSignInProvider) {
                NSLog(@"Unable to locate the SignIn Provider SDK. Signing Out any existing session...");
                [self wipeAll];
            }
            
            if (self.currentSignInProvider) {
                [self activateProvider: self.currentSignInProvider];
                if ([self.currentSignInProvider interceptApplication:application
                                       didFinishLaunchingWithOptions:launchOptions]) {
                }
            }
        }
    }
    
    return YES;
}

- (BOOL)interceptApplication:(UIApplication *)application
                     openURL:(NSURL *)url
           sourceApplication:(NSString *)sourceApplication
                  annotation:(id)annotation {
    if (self.currentSignInProvider) {
        return [self.currentSignInProvider interceptApplication:application
                                                        openURL:url
                                              sourceApplication:sourceApplication
                                                     annotation:annotation];
    }
    else {
        return YES;
    }
}

@end
