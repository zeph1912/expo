/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "ABI46_0_0RCTSurfacePresenter.h"

#import <mutex>

#import <ABI46_0_0React/ABI46_0_0RCTAssert.h>
#import <ABI46_0_0React/ABI46_0_0RCTBridge+Private.h>
#import <ABI46_0_0React/ABI46_0_0RCTComponentViewFactory.h>
#import <ABI46_0_0React/ABI46_0_0RCTComponentViewRegistry.h>
#import <ABI46_0_0React/ABI46_0_0RCTConstants.h>
#import <ABI46_0_0React/ABI46_0_0RCTFabricSurface.h>
#import <ABI46_0_0React/ABI46_0_0RCTFollyConvert.h>
#import <ABI46_0_0React/ABI46_0_0RCTI18nUtil.h>
#import <ABI46_0_0React/ABI46_0_0RCTMountingManager.h>
#import <ABI46_0_0React/ABI46_0_0RCTMountingManagerDelegate.h>
#import <ABI46_0_0React/ABI46_0_0RCTScheduler.h>
#import <ABI46_0_0React/ABI46_0_0RCTSurfaceRegistry.h>
#import <ABI46_0_0React/ABI46_0_0RCTSurfaceView+Internal.h>
#import <ABI46_0_0React/ABI46_0_0RCTSurfaceView.h>
#import <ABI46_0_0React/ABI46_0_0RCTUtils.h>

#import <ABI46_0_0React/ABI46_0_0config/ABI46_0_0ReactNativeConfig.h>
#import <ABI46_0_0React/ABI46_0_0renderer/componentregistry/ComponentDescriptorFactory.h>
#import <ABI46_0_0React/ABI46_0_0renderer/runtimescheduler/RuntimeScheduler.h>
#import <ABI46_0_0React/ABI46_0_0renderer/scheduler/AsynchronousEventBeat.h>
#import <ABI46_0_0React/ABI46_0_0renderer/scheduler/SchedulerToolbox.h>
#import <ABI46_0_0React/ABI46_0_0renderer/scheduler/SynchronousEventBeat.h>
#import <ABI46_0_0React/ABI46_0_0utils/ContextContainer.h>
#import <ABI46_0_0React/ABI46_0_0utils/ManagedObjectWrapper.h>

#import "ABI46_0_0PlatformRunLoopObserver.h"
#import "ABI46_0_0RCTConversions.h"

using namespace ABI46_0_0facebook::ABI46_0_0React;

static dispatch_queue_t ABI46_0_0RCTGetBackgroundQueue()
{
  static dispatch_queue_t queue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    dispatch_queue_attr_t attr =
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    queue = dispatch_queue_create("com.facebook.ABI46_0_0React.background", attr);
  });
  return queue;
}

static BackgroundExecutor ABI46_0_0RCTGetBackgroundExecutor()
{
  return [](std::function<void()> &&callback) {
    if (ABI46_0_0RCTIsMainQueue()) {
      callback();
      return;
    }

    auto copyableCallback = callback;
    dispatch_async(ABI46_0_0RCTGetBackgroundQueue(), ^{
      copyableCallback();
    });
  };
}

@interface ABI46_0_0RCTSurfacePresenter () <ABI46_0_0RCTSchedulerDelegate, ABI46_0_0RCTMountingManagerDelegate>
@end

@implementation ABI46_0_0RCTSurfacePresenter {
  ABI46_0_0RCTMountingManager *_mountingManager; // Thread-safe.
  ABI46_0_0RCTSurfaceRegistry *_surfaceRegistry; // Thread-safe.

  std::mutex _schedulerAccessMutex;
  std::mutex _schedulerLifeCycleMutex;
  ABI46_0_0RCTScheduler *_Nullable _scheduler; // Thread-safe. Pointer is protected by `_schedulerAccessMutex`.
  ContextContainer::Shared _contextContainer; // Protected by `_schedulerLifeCycleMutex`.
  RuntimeExecutor _runtimeExecutor; // Protected by `_schedulerLifeCycleMutex`.

  butter::shared_mutex _observerListMutex;
  std::vector<__weak id<ABI46_0_0RCTSurfacePresenterObserver>> _observers; // Protected by `_observerListMutex`.
}

- (instancetype)initWithContextContainer:(ContextContainer::Shared)contextContainer
                         runtimeExecutor:(RuntimeExecutor)runtimeExecutor
{
  if (self = [super init]) {
    assert(contextContainer && "RuntimeExecutor must be not null.");
    _runtimeExecutor = runtimeExecutor;
    _contextContainer = contextContainer;

    _surfaceRegistry = [ABI46_0_0RCTSurfaceRegistry new];
    _mountingManager = [ABI46_0_0RCTMountingManager new];
    _mountingManager.contextContainer = contextContainer;
    _mountingManager.delegate = self;

    _scheduler = [self _createScheduler];

    auto ABI46_0_0ReactNativeConfig = _contextContainer->at<std::shared_ptr<ABI46_0_0ReactNativeConfig const>>("ABI46_0_0ReactNativeConfig");
    if (ABI46_0_0ReactNativeConfig->getBool("ABI46_0_0React_native_new_architecture:suspend_before_app_termination")) {
      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(_applicationWillTerminate)
                                                   name:UIApplicationWillTerminateNotification
                                                 object:nil];
    }
  }

  return self;
}

- (ABI46_0_0RCTMountingManager *)mountingManager
{
  return _mountingManager;
}

- (ABI46_0_0RCTScheduler *_Nullable)scheduler
{
  std::lock_guard<std::mutex> lock(_schedulerAccessMutex);
  return _scheduler;
}

- (ContextContainer::Shared)contextContainer
{
  std::lock_guard<std::mutex> lock(_schedulerLifeCycleMutex);
  return _contextContainer;
}

- (void)setContextContainer:(ContextContainer::Shared)contextContainer
{
  std::lock_guard<std::mutex> lock(_schedulerLifeCycleMutex);
  _contextContainer = contextContainer;
  _mountingManager.contextContainer = contextContainer;
}

- (RuntimeExecutor)runtimeExecutor
{
  std::lock_guard<std::mutex> lock(_schedulerLifeCycleMutex);
  return _runtimeExecutor;
}

- (void)setRuntimeExecutor:(RuntimeExecutor)runtimeExecutor
{
  std::lock_guard<std::mutex> lock(_schedulerLifeCycleMutex);
  _runtimeExecutor = runtimeExecutor;
}

#pragma mark - Internal Surface-dedicated Interface

- (void)registerSurface:(ABI46_0_0RCTFabricSurface *)surface
{
  [_surfaceRegistry registerSurface:surface];
  ABI46_0_0RCTScheduler *scheduler = [self scheduler];
  if (scheduler) {
    [scheduler registerSurface:surface.surfaceHandler];
  }
}

- (void)unregisterSurface:(ABI46_0_0RCTFabricSurface *)surface
{
  ABI46_0_0RCTScheduler *scheduler = [self scheduler];
  if (scheduler) {
    [scheduler unregisterSurface:surface.surfaceHandler];
  }
  [_surfaceRegistry unregisterSurface:surface];
}

- (ABI46_0_0RCTFabricSurface *)surfaceForRootTag:(ABI46_0_0ReactTag)rootTag
{
  return [_surfaceRegistry surfaceForRootTag:rootTag];
}

- (id<ABI46_0_0RCTSurfaceProtocol>)createFabricSurfaceForModuleName:(NSString *)moduleName
                                         initialProperties:(NSDictionary *)initialProperties
{
  return [[ABI46_0_0RCTFabricSurface alloc] initWithSurfacePresenter:self
                                                 moduleName:moduleName
                                          initialProperties:initialProperties];
}

- (UIView *)findComponentViewWithTag_DO_NOT_USE_DEPRECATED:(NSInteger)tag
{
  UIView<ABI46_0_0RCTComponentViewProtocol> *componentView =
      [_mountingManager.componentViewRegistry findComponentViewWithTag:tag];
  return componentView;
}

- (BOOL)synchronouslyUpdateViewOnUIThread:(NSNumber *)ABI46_0_0ReactTag props:(NSDictionary *)props
{
  ABI46_0_0RCTScheduler *scheduler = [self scheduler];
  if (!scheduler) {
    return NO;
  }

  ABI46_0_0ReactTag tag = [ABI46_0_0ReactTag integerValue];
  UIView<ABI46_0_0RCTComponentViewProtocol> *componentView =
      [_mountingManager.componentViewRegistry findComponentViewWithTag:tag];
  if (componentView == nil) {
    return NO; // This view probably isn't managed by Fabric
  }
  ComponentHandle handle = [[componentView class] componentDescriptorProvider].handle;
  auto *componentDescriptor = [scheduler findComponentDescriptorByHandle_DO_NOT_USE_THIS_IS_BROKEN:handle];

  if (!componentDescriptor) {
    return YES;
  }

  [_mountingManager synchronouslyUpdateViewOnUIThread:tag changedProps:props componentDescriptor:*componentDescriptor];
  return YES;
}

- (void)setupAnimationDriverWithSurfaceHandler:(ABI46_0_0facebook::ABI46_0_0React::SurfaceHandler const &)surfaceHandler
{
  [[self scheduler] setupAnimationDriver:surfaceHandler];
}

- (BOOL)suspend
{
  std::lock_guard<std::mutex> lock(_schedulerLifeCycleMutex);

  ABI46_0_0RCTScheduler *scheduler;
  {
    std::lock_guard<std::mutex> accessLock(_schedulerAccessMutex);

    if (!_scheduler) {
      return NO;
    }
    scheduler = _scheduler;
    _scheduler = nil;
  }

  [self _stopAllSurfacesWithScheduler:scheduler];

  return YES;
}

- (BOOL)resume
{
  std::lock_guard<std::mutex> lock(_schedulerLifeCycleMutex);

  ABI46_0_0RCTScheduler *scheduler;
  {
    std::lock_guard<std::mutex> accessLock(_schedulerAccessMutex);

    if (_scheduler) {
      return NO;
    }
    scheduler = [self _createScheduler];
  }

  [self _startAllSurfacesWithScheduler:scheduler];

  {
    std::lock_guard<std::mutex> accessLock(_schedulerAccessMutex);
    _scheduler = scheduler;
  }

  return YES;
}

#pragma mark - Private

- (ABI46_0_0RCTScheduler *)_createScheduler
{
  auto ABI46_0_0ReactNativeConfig = _contextContainer->at<std::shared_ptr<ABI46_0_0ReactNativeConfig const>>("ABI46_0_0ReactNativeConfig");

  if (ABI46_0_0ReactNativeConfig && ABI46_0_0ReactNativeConfig->getBool("ABI46_0_0React_fabric:preemptive_view_allocation_disabled_ios")) {
    ABI46_0_0RCTExperimentSetPreemptiveViewAllocationDisabled(YES);
  }

  if (ABI46_0_0ReactNativeConfig && ABI46_0_0ReactNativeConfig->getBool("rn_convergence:dispatch_pointer_events")) {
    ABI46_0_0RCTSetDispatchW3CPointerEvents(YES);
  }

  auto componentRegistryFactory =
      [factory = wrapManagedObject(_mountingManager.componentViewRegistry.componentViewFactory)](
          EventDispatcher::Weak const &eventDispatcher, ContextContainer::Shared const &contextContainer) {
        return [(ABI46_0_0RCTComponentViewFactory *)unwrapManagedObject(factory)
            createComponentDescriptorRegistryWithParameters:{eventDispatcher, contextContainer}];
      };

  auto runtimeExecutor = _runtimeExecutor;

  auto toolbox = SchedulerToolbox{};
  toolbox.contextContainer = _contextContainer;
  toolbox.componentRegistryFactory = componentRegistryFactory;

  auto weakRuntimeScheduler = _contextContainer->find<std::weak_ptr<RuntimeScheduler>>("RuntimeScheduler");
  auto runtimeScheduler = weakRuntimeScheduler.has_value() ? weakRuntimeScheduler.value().lock() : nullptr;
  if (runtimeScheduler) {
    runtimeScheduler->setEnableYielding(true);
    runtimeExecutor = [runtimeScheduler](std::function<void(jsi::Runtime & runtime)> &&callback) {
      runtimeScheduler->scheduleWork(std::move(callback));
    };
  }

  toolbox.runtimeExecutor = runtimeExecutor;

  toolbox.mainRunLoopObserverFactory = [](RunLoopObserver::Activity activities,
                                          RunLoopObserver::WeakOwner const &owner) {
    return std::make_unique<MainRunLoopObserver>(activities, owner);
  };

  toolbox.backgroundExecutor = ABI46_0_0RCTGetBackgroundExecutor();

  toolbox.synchronousEventBeatFactory =
      [runtimeExecutor, runtimeScheduler = runtimeScheduler](EventBeat::SharedOwnerBox const &ownerBox) {
        auto runLoopObserver =
            std::make_unique<MainRunLoopObserver const>(RunLoopObserver::Activity::BeforeWaiting, ownerBox->owner);
        return std::make_unique<SynchronousEventBeat>(std::move(runLoopObserver), runtimeExecutor, runtimeScheduler);
      };

  toolbox.asynchronousEventBeatFactory =
      [runtimeExecutor](EventBeat::SharedOwnerBox const &ownerBox) -> std::unique_ptr<EventBeat> {
    auto runLoopObserver =
        std::make_unique<MainRunLoopObserver const>(RunLoopObserver::Activity::BeforeWaiting, ownerBox->owner);
    return std::make_unique<AsynchronousEventBeat>(std::move(runLoopObserver), runtimeExecutor);
  };

  ABI46_0_0RCTScheduler *scheduler = [[ABI46_0_0RCTScheduler alloc] initWithToolbox:toolbox];
  scheduler.delegate = self;

  return scheduler;
}

- (void)_startAllSurfacesWithScheduler:(ABI46_0_0RCTScheduler *)scheduler
{
  [_surfaceRegistry enumerateWithBlock:^(NSEnumerator<ABI46_0_0RCTFabricSurface *> *enumerator) {
    for (ABI46_0_0RCTFabricSurface *surface in enumerator) {
      [scheduler registerSurface:surface.surfaceHandler];
      [surface start];
    }
  }];
}

- (void)_stopAllSurfacesWithScheduler:(ABI46_0_0RCTScheduler *)scheduler
{
  [_surfaceRegistry enumerateWithBlock:^(NSEnumerator<ABI46_0_0RCTFabricSurface *> *enumerator) {
    for (ABI46_0_0RCTFabricSurface *surface in enumerator) {
      [surface stop];
      [scheduler unregisterSurface:surface.surfaceHandler];
    }
  }];
}

- (void)_applicationWillTerminate
{
  [self suspend];
}

#pragma mark - ABI46_0_0RCTSchedulerDelegate

- (void)schedulerDidFinishTransaction:(MountingCoordinator::Shared const &)mountingCoordinator
{
  [_mountingManager scheduleTransaction:mountingCoordinator];
}

- (void)schedulerDidDispatchCommand:(ShadowView const &)shadowView
                        commandName:(std::string const &)commandName
                               args:(folly::dynamic const &)args
{
  ABI46_0_0ReactTag tag = shadowView.tag;
  NSString *commandStr = [[NSString alloc] initWithUTF8String:commandName.c_str()];
  NSArray *argsArray = convertFollyDynamicToId(args);

  [self->_mountingManager dispatchCommand:tag commandName:commandStr args:argsArray];
}

- (void)schedulerDidSendAccessibilityEvent:(const ABI46_0_0facebook::ABI46_0_0React::ShadowView &)shadowView
                                 eventType:(const std::string &)eventType
{
  ABI46_0_0ReactTag tag = shadowView.tag;
  NSString *eventTypeStr = [[NSString alloc] initWithUTF8String:eventType.c_str()];

  [self->_mountingManager sendAccessibilityEvent:tag eventType:eventTypeStr];
}

- (void)schedulerDidSetIsJSResponder:(BOOL)isJSResponder
                blockNativeResponder:(BOOL)blockNativeResponder
                       forShadowView:(ABI46_0_0facebook::ABI46_0_0React::ShadowView const &)shadowView;
{
  [self->_mountingManager setIsJSResponder:isJSResponder
                      blockNativeResponder:blockNativeResponder
                             forShadowView:shadowView];
}

- (void)addObserver:(id<ABI46_0_0RCTSurfacePresenterObserver>)observer
{
  std::unique_lock<butter::shared_mutex> lock(_observerListMutex);
  _observers.push_back(observer);
}

- (void)removeObserver:(id<ABI46_0_0RCTSurfacePresenterObserver>)observer
{
  std::unique_lock<butter::shared_mutex> lock(_observerListMutex);
  std::vector<__weak id<ABI46_0_0RCTSurfacePresenterObserver>>::const_iterator it =
      std::find(_observers.begin(), _observers.end(), observer);
  if (it != _observers.end()) {
    _observers.erase(it);
  }
}

#pragma mark - ABI46_0_0RCTMountingManagerDelegate

- (void)mountingManager:(ABI46_0_0RCTMountingManager *)mountingManager willMountComponentsWithRootTag:(ABI46_0_0ReactTag)rootTag
{
  ABI46_0_0RCTAssertMainQueue();

  NSArray<id<ABI46_0_0RCTSurfacePresenterObserver>> *observersCopy;
  {
    std::shared_lock<butter::shared_mutex> lock(_observerListMutex);
    observersCopy = [self _getObservers];
  }

  for (id<ABI46_0_0RCTSurfacePresenterObserver> observer in observersCopy) {
    if ([observer respondsToSelector:@selector(willMountComponentsWithRootTag:)]) {
      [observer willMountComponentsWithRootTag:rootTag];
    }
  }
}

- (void)mountingManager:(ABI46_0_0RCTMountingManager *)mountingManager didMountComponentsWithRootTag:(ABI46_0_0ReactTag)rootTag
{
  ABI46_0_0RCTAssertMainQueue();

  NSArray<id<ABI46_0_0RCTSurfacePresenterObserver>> *observersCopy;
  {
    std::shared_lock<butter::shared_mutex> lock(_observerListMutex);
    observersCopy = [self _getObservers];
  }

  for (id<ABI46_0_0RCTSurfacePresenterObserver> observer in observersCopy) {
    if ([observer respondsToSelector:@selector(didMountComponentsWithRootTag:)]) {
      [observer didMountComponentsWithRootTag:rootTag];
    }
  }
}

- (NSArray<id<ABI46_0_0RCTSurfacePresenterObserver>> *)_getObservers
{
  NSMutableArray<id<ABI46_0_0RCTSurfacePresenterObserver>> *observersCopy = [NSMutableArray new];
  for (id<ABI46_0_0RCTSurfacePresenterObserver> observer : _observers) {
    if (observer) {
      [observersCopy addObject:observer];
    }
  }

  return observersCopy;
}

@end
