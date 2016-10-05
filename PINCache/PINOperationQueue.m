//
//  PINOperationQueue.m
//  Pods
//
//  Created by Garrett Moon on 8/23/16.
//
//

#import "PINOperationQueue.h"
#import <pthread.h>

@interface NSNumber (PINOperationQueue) <PINOperationReference>

@end

@interface PINOperationQueue () {
  pthread_mutex_t _lock;
  //increments with every operation to allow cancelation
  NSUInteger _operationReferenceCount;
  
  dispatch_queue_t _serialQueue;
  BOOL _serialQueueBusy;
  
  dispatch_semaphore_t _concurrentSemaphore;
  dispatch_queue_t _concurrentQueue;
  dispatch_queue_t _semaphoreQueue;
  
  NSMutableOrderedSet *_queuedOperations;
  NSMutableOrderedSet *_lowPriorityOperations;
  NSMutableOrderedSet *_defaultPriorityOperations;
  NSMutableOrderedSet *_highPriorityOperations;
  
  NSMapTable *_referenceToOperations;
  
  NSArray <NSMutableOrderedSet *> *_prioritizedOperationQueues;
}

@end

@interface PINOperation : NSObject

@property (nonatomic, strong) dispatch_block_t block;
@property (nonatomic, strong) id <PINOperationReference> reference;

+ (instancetype)operationWithBlock:(dispatch_block_t)block reference:(id <PINOperationReference>)reference;

@end

@implementation PINOperation

+ (instancetype)operationWithBlock:(dispatch_block_t)block reference:(id<PINOperationReference>)reference
{
  PINOperation *operation = [[self alloc] init];
  operation.block = block;
  operation.reference = reference;

  return operation;
}

@end

@implementation PINOperationQueue

- (instancetype)initWithMaxConcurrentOperations:(NSUInteger)maxConcurrentOperations
{
  return [self initWithMaxConcurrentOperations:maxConcurrentOperations concurrentQueue:dispatch_queue_create("PINOperationQueue Unprioritized Serial Queue", DISPATCH_QUEUE_CONCURRENT)];
}

- (instancetype)initWithMaxConcurrentOperations:(NSUInteger)maxConcurrentOperations concurrentQueue:(dispatch_queue_t)concurrentQueue
{
  if (self = [super init]) {
    NSAssert(maxConcurrentOperations > 1, @"Max concurrent operations must be greater than 1. If it's one, just use a serial queue!");
    _operationReferenceCount = 0;
    
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    //mutex must be recursive to allow scheduling of operations from operations
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&_lock, &attr);
    
    _serialQueue = dispatch_queue_create("PINOperationQueue Serial Queue", DISPATCH_QUEUE_SERIAL);
    
    _concurrentQueue = concurrentQueue;
    
    //Create a queue with max - 1 because this plus the serial queue add up to max.
    _concurrentSemaphore = dispatch_semaphore_create(maxConcurrentOperations - 1);
    _semaphoreQueue = dispatch_queue_create("PINOperationQueue Serial Semaphore Queue", DISPATCH_QUEUE_SERIAL);
    
    _queuedOperations = [[NSMutableOrderedSet alloc] init];
    _lowPriorityOperations = [[NSMutableOrderedSet alloc] init];
    _defaultPriorityOperations = [[NSMutableOrderedSet alloc] init];
    _highPriorityOperations = [[NSMutableOrderedSet alloc] init];
    
    _prioritizedOperationQueues = @[_highPriorityOperations, _defaultPriorityOperations, _lowPriorityOperations];
    
    _referenceToOperations = [NSMapTable weakToWeakObjectsMapTable];
  }
  return self;
}

- (void)dealloc
{
  pthread_mutex_destroy(&_lock);
}

- (id <PINOperationReference>)nextOperationReference
{
  [self lock];
    id <PINOperationReference> reference = [NSNumber numberWithUnsignedInteger:++_operationReferenceCount];
  [self unlock];
  return reference;
}

- (id <PINOperationReference>)addOperation:(dispatch_block_t)block withPriority:(PINOperationQueuePriority)priority
{
  id <PINOperationReference> reference = [self nextOperationReference];
  
  NSMutableOrderedSet *queue = [self operationQueueWithPriority:priority];
  
  PINOperation *operation = [PINOperation operationWithBlock:block reference:reference];
  
  [self lock];
    [queue addObject:operation];
    [_queuedOperations addObject:operation];
    [_referenceToOperations setObject:operation forKey:reference];
  [self unlock];
  
  [self scheduleNextOperations:NO];
  
  return reference;
}

- (void)cancelOperation:(id <PINOperationReference>)operationReference
{
  [self lock];
    PINOperation *operation = [_referenceToOperations objectForKey:operationReference];
    if (operation) {
      for (NSMutableOrderedSet *queue in _prioritizedOperationQueues) {
        [queue removeObject:operation];
      }
      [_queuedOperations removeObject:operation];
    }
  [self unlock];
}

- (void)setOperationPriority:(PINOperationQueuePriority)priority withReference:(id <PINOperationReference>)operationReference
{
  [self lock];
    PINOperation *operation = [_referenceToOperations objectForKey:operationReference];
    if (operation) {
      for (NSMutableOrderedSet *queue in _prioritizedOperationQueues) {
        [queue removeObject:operation];
      }
      NSMutableOrderedSet *queue = [self operationQueueWithPriority:priority];
      [queue addObject:operation];
    }
  [self unlock];
}

/**
 Schedule next operations schedules the next operation by queue order onto the serial queue if
 it's available and one operation by priority order onto the concurrent queue.
 */
- (void)scheduleNextOperations:(BOOL)onlyCheckSerial
{
  [self lock];
    //get next available operation in order, ignoring priority and run it on the serial queue
    if (_serialQueueBusy == NO) {
      PINOperation *operation = [self locked_nextOperationByQueue];
      if (operation) {
        _serialQueueBusy = YES;
        dispatch_async(_serialQueue, ^{
          operation.block();
          [self lock];
            _serialQueueBusy = NO;
          [self unlock];
          
          //see if there are any other operations
          [self scheduleNextOperations:YES];
        });
      }
    }
  [self unlock];
  
  if (onlyCheckSerial) {
    return;
  }
  
  dispatch_async(_semaphoreQueue, ^{
      dispatch_semaphore_wait(_concurrentSemaphore, DISPATCH_TIME_FOREVER);
      [self lock];
        PINOperation *operation = [self locked_nextOperationByPriority];
      [self unlock];
    
      if (operation) {
        dispatch_async(_concurrentQueue, ^{
          operation.block();
          dispatch_semaphore_signal(_concurrentSemaphore);
        });
      } else {
        dispatch_semaphore_signal(_concurrentSemaphore);
      }
  });
}

- (NSMutableOrderedSet *)operationQueueWithPriority:(PINOperationQueuePriority)priority
{
  switch (priority) {
    case PINOperationQueuePriorityLow:
      return _lowPriorityOperations;
      
    default:
      NSAssert(NO, @"Invalid priority set");
    case PINOperationQueuePriorityDefault:
      return _defaultPriorityOperations;
      
    case PINOperationQueuePriorityHigh:
      return _highPriorityOperations;
  }
}

//Call with lock held
- (PINOperation *)locked_nextOperationByPriority
{
  for (NSOrderedSet *queue in _prioritizedOperationQueues) {
    PINOperation *operation = [queue firstObject];
    if (operation) {
      [self locked_removeOperation:operation];
      return operation;
    }
  }
  return nil;
}

//Call with lock held
- (PINOperation *)locked_nextOperationByQueue
{
  PINOperation *operation = [_queuedOperations firstObject];
  [self locked_removeOperation:operation];
  return operation;
}

//Call with lock held
- (void)locked_removeOperation:(PINOperation *)operation
{
  if (operation) {
    [_queuedOperations removeObject:operation];
    [_lowPriorityOperations removeObject:operation];
    [_defaultPriorityOperations removeObject:operation];
    [_highPriorityOperations removeObject:operation];
  }
}

- (void)lock
{
  pthread_mutex_lock(&_lock);
}

- (void)unlock
{
  pthread_mutex_unlock(&_lock);
}

@end
