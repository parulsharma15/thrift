/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements. See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership. The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License. You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

#import <Foundation/Foundation.h>
#import "TSocketServer.h"
#import "TNSFileHandleTransport.h"
#import "TProtocol.h"
#import "TTransportException.h"
#import "TObjective-C.h"
#import <sys/socket.h>
#include <netinet/in.h>



NSString * const kTSocketServer_ClientConnectionFinishedForProcessorNotification = @"TSocketServer_ClientConnectionFinishedForProcessorNotification";
NSString * const kTSocketServer_ProcessorKey = @"TSocketServer_Processor";
NSString * const kTSockerServer_TransportKey = @"TSockerServer_Transport";

@interface TSocketServer ()

@property (nonatomic) NSMutableSet *clientSockets;
@property (nonatomic) dispatch_queue_t clientSocketQueue;

@end


@implementation TSocketServer

- (id) initWithPort: (int) port
    protocolFactory: (id <TProtocolFactory>) protocolFactory
   processorFactory: (id <TProcessorFactory>) processorFactory;
{
    self = [super init];
    
    mInputProtocolFactory = [protocolFactory retain_stub];
    mOutputProtocolFactory = [protocolFactory retain_stub];
    mProcessorFactory = [processorFactory retain_stub];
    
    // create a socket.
    int fd = -1;
    CFSocketRef socket = CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP, 0, NULL, NULL);
    if (socket) {
        CFSocketSetSocketFlags(socket, CFSocketGetSocketFlags(socket) & ~kCFSocketCloseOnInvalidate);
        fd = CFSocketGetNative(socket);
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (void *)&yes, sizeof(yes));
        
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_len = sizeof(addr);
        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        NSData *address = [NSData dataWithBytes:&addr length:sizeof(addr)];
        if (CFSocketSetAddress(socket, (bridge_stub CFDataRef)address) != kCFSocketSuccess) {
            CFSocketInvalidate(socket);
            CFRelease(socket);
            NSLog(@"*** Could not bind to address");
            return nil;
        }
    } else {
        NSLog(@"*** No server socket");
        return nil;
    }
    
    // wrap it in a file handle so we can get messages from it
    mSocketFileHandle = [[NSFileHandle alloc] initWithFileDescriptor: fd
                                                      closeOnDealloc: YES];
    
    // throw away our socket
    CFSocketInvalidate(socket);
    CFRelease(socket);
    
    self.clientSockets = [[NSMutableSet alloc] init];
    self.clientSocketQueue = dispatch_queue_create("org.apache.thrift.tsocketserver.queue", DISPATCH_QUEUE_SERIAL);
    
    // register for notifications of accepted incoming connections
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(connectionAccepted:)
                                                 name: NSFileHandleConnectionAcceptedNotification
                                               object: mSocketFileHandle];
    
    // tell socket to listen
    [mSocketFileHandle acceptConnectionInBackgroundAndNotify];
    
    NSLog(@"Listening on TCP port %d", self.port);
    
    return self;
}


- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [mInputProtocolFactory release_stub];
    [mOutputProtocolFactory release_stub];
    [mProcessorFactory release_stub];
    [mSocketFileHandle release_stub];
    [super dealloc_stub];
}

- (int)port
{
    // Get server port from File handle
    int32_t port = 0;
    unsigned int sockaddrLength = sizeof(struct sockaddr_in);
    struct sockaddr_in sockaddr;
    if(getsockname([mSocketFileHandle fileDescriptor], (struct sockaddr *)&sockaddr, &sockaddrLength) == -1) {
        NSLog(@"Cannot get local port number for socket \n");
    }
    else {
        port = sockaddr.sin_port;
    }
    
    return htons(port);
}

- (void) connectionAccepted: (NSNotification *) aNotification
{
    NSLog(@"Connection accepted on port: %d", self.port);
    NSFileHandle * socket = [[aNotification userInfo] objectForKey: NSFileHandleNotificationFileHandleItem];
    
    dispatch_sync(self.clientSocketQueue, ^{
        [self.clientSockets addObject:socket];
    });

    // now that we have a client connected, spin off a thread to handle activity
    [NSThread detachNewThreadSelector: @selector(handleClientConnection:)
                             toTarget: self
                           withObject: socket];
    
    [[aNotification object] acceptConnectionInBackgroundAndNotify];
}


- (void) handleClientConnection: (NSFileHandle *) clientSocket
{
#if __has_feature(objc_arc)
    @autoreleasepool {
        TNSFileHandleTransport * transport = [[TNSFileHandleTransport alloc] initWithFileHandle: clientSocket];
        id<TProcessor> processor = [mProcessorFactory processorForTransport: transport];
        
        id <TProtocol> inProtocol = [mInputProtocolFactory newProtocolOnTransport: transport];
        id <TProtocol> outProtocol = [mOutputProtocolFactory newProtocolOnTransport: transport];
        
        @try {
            BOOL result = NO;
            do {
                @autoreleasepool {
                    result = [processor processOnInputProtocol: inProtocol outputProtocol: outProtocol];
                }
            } while (result);
        }
        @catch (TTransportException * te) {
            //NSLog(@"Caught transport exception, abandoning client connection: %@", te);
        }
        
        NSNotification * n = [NSNotification notificationWithName: kTSocketServer_ClientConnectionFinishedForProcessorNotification
                                                           object: self
                                                         userInfo: [NSDictionary dictionaryWithObjectsAndKeys:
                                                                    processor,
                                                                    kTSocketServer_ProcessorKey,
                                                                    transport,
                                                                    kTSockerServer_TransportKey,
                                                                    nil]];
        [[NSNotificationCenter defaultCenter] performSelectorOnMainThread: @selector(postNotification:) withObject: n waitUntilDone: YES];
        
        dispatch_sync(self.clientSocketQueue, ^{
            [self.clientSockets removeObject:clientSocket];
        });
        
    }
#else
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    
    TNSFileHandleTransport * transport = [[TNSFileHandleTransport alloc] initWithFileHandle: clientSocket];
    id<TProcessor> processor = [mProcessorFactory processorForTransport: transport];
    
    id <TProtocol> inProtocol = [[mInputProtocolFactory newProtocolOnTransport: transport] autorelease];
    id <TProtocol> outProtocol = [[mOutputProtocolFactory newProtocolOnTransport: transport] autorelease];
    
    @try {
        BOOL result = NO;
        do {
            NSAutoreleasePool * myPool = [[NSAutoreleasePool alloc] init];
            result = [processor processOnInputProtocol: inProtocol outputProtocol: outProtocol];
            [myPool release];
        } while (result);
    }
    @catch (TTransportException * te) {
        //NSLog(@"Caught transport exception, abandoning client connection: %@", te);
    }
    
    NSNotification * n = [NSNotification notificationWithName: kTSocketServer_ClientConnectionFinishedForProcessorNotification
                                                       object: self
                                                     userInfo: [NSDictionary dictionaryWithObjectsAndKeys:
                                                                processor,
                                                                kTSocketServer_ProcessorKey,
                                                                transport,
                                                                kTSockerServer_TransportKey,
                                                                nil]];
    [[NSNotificationCenter defaultCenter] performSelectorOnMainThread: @selector(postNotification:) withObject: n waitUntilDone: YES];
    
    [pool release];
#endif
}

- (void)stop
{
    dispatch_sync(self.clientSocketQueue, ^{
        [self.clientSockets enumerateObjectsUsingBlock:^(NSFileHandle *  _Nonnull clientSocket, BOOL * _Nonnull stop) {
            [clientSocket closeFile];
        }];
    });
}

@end



