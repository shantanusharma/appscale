#!/usr/bin/env python
#
# Copyright 2007 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#




"""Base class for implementing RPC of API proxy stubs."""








# AppScale: os and threading are needed to implement async-capable RPC.
import os
import sys
import threading

class RPC(object):
  """Base class for implementing RPC of API proxy stubs.

  To implement a RPC to make real asynchronous API call:
    - Extend this class.
    - Override _MakeCallImpl and/or _WaitImpl to do a real asynchronous call.
  """

  IDLE = 0
  RUNNING = 1
  FINISHING = 2

  def __init__(self, package=None, call=None, request=None, response=None,
               callback=None, deadline=None, stub=None):
    """Constructor for the RPC object.

    All arguments are optional, and simply set members on the class.
    These data members will be overriden by values passed to MakeCall.

    Args:
      package: string, the package for the call
      call: string, the call within the package
      request: ProtocolMessage instance, appropriate for the arguments
      response: ProtocolMessage instance, appropriate for the response
      callback: callable, called when call is complete
      deadline: A double specifying the deadline for this call as the number of
                seconds from the current time. Ignored if non-positive.
      stub: APIProxyStub instance, used in default _WaitImpl to do real call
    """
    self._exception = None
    self._state = RPC.IDLE
    self._traceback = None

    self.package = package
    self.call = call
    self.request = request
    self.response = response
    self.callback = callback
    self.deadline = deadline
    self.stub = stub
    self.cpu_usage_mcycles = 0

  def Clone(self):
    """Make a shallow copy of this instances attributes, excluding methods.

    This is usually used when an RPC has been specified with some configuration
    options and is being used as a template for multiple RPCs outside of a
    developer's easy control.
    """
    if self._state != RPC.IDLE:
      raise AssertionError('Cannot clone a call already in progress')

    clone = self.__class__()
    for k, v in self.__dict__.iteritems():
      setattr(clone, k, v)
    return clone

  def MakeCall(self, package=None, call=None, request=None, response=None,
               callback=None, deadline=None):
    """Makes an asynchronous (i.e. non-blocking) API call within the
    specified package for the specified call method.

    It will call the _MakeRealCall to do the real job.

    Args:
      Same as constructor; see __init__.

    Raises:
      TypeError or AssertionError if an argument is of an invalid type.
      AssertionError or RuntimeError is an RPC is already in use.
    """
    self.callback = callback or self.callback
    self.package = package or self.package
    self.call = call or self.call
    self.request = request or self.request
    self.response = response or self.response
    self.deadline = deadline or self.deadline

    assert self._state is RPC.IDLE, ('RPC for %s.%s has already been started' %
                                      (self.package, self.call))
    assert self.callback is None or callable(self.callback)
    self._MakeCallImpl()

  def Wait(self):
    """Waits on the API call associated with this RPC."""
    rpc_completed = self._WaitImpl()

    assert rpc_completed, ('RPC for %s.%s was not completed, and no other '
                           'exception was raised ' % (self.package, self.call))

  def CheckSuccess(self):
    """If there was an exception, raise it now.

    Raises:
      Exception of the API call or the callback, if any.
    """
    if self._exception and self._traceback:
      raise self._exception.__class__, self._exception, self._traceback
    elif self._exception:
      raise self._exception

  @property
  def exception(self):
    return self._exception

  @property
  def state(self):
    return self._state

  def _MakeCallImpl(self):
    """Override this method to implement a real asynchronous call rpc."""
    self._state = RPC.RUNNING

  def _WaitImpl(self):
    """Override this method to implement a real asynchronous call rpc.

    Returns:
      True if the async call was completed successfully.
    """
    try:
      try:
        self.stub.MakeSyncCall(self.package, self.call,
                               self.request, self.response)
      except Exception:
        _, self._exception, self._traceback = sys.exc_info()
    finally:
      self._state = RPC.FINISHING
      self._Callback()

    return True

  def _Callback(self):
    if self.callback:
      try:
        self.callback()
      except:
        _, self._exception, self._traceback = sys.exc_info()
        self._exception._appengine_apiproxy_rpc = self
        raise

# AppScale: Use thread to start RPC during _MakeCallImpl instead of during
# _WaitImpl.
class RealRPC(RPC):
  """ Overrides the RPC class to implement real asynchronous RPC calls using 
      Threads.
  """
  def __init__(self, stub=None):
    """ Create a RealRPC instance.

    Args:
      stub: A stub instance that handles the actual call.
    """
    super(RealRPC, self).__init__(stub=stub)
    self._exc_info = None
    self._exc_info_lock = threading.Lock()

  def _MakeCallImpl(self):
    """ Starts the thread which calls upon the service RPC."""
    args = [self.package, self.call, self.request, self.response]

    # If this call is made in the sandbox, pass the request ID and environment
    # variables explicitly since they are lost in new threads.
    if hasattr(self.stub, '_GetRequestId'):
      args.extend([self.stub._GetRequestId(), os.environ.copy()])

    self._thread = threading.Thread(target=self._make_sync_call, args=args)
    self._thread.start()
    self._state = RPC.RUNNING

  def _WaitImpl(self):
    """ Waiting on an RPC call thread to complete """
    self._thread.join()
    with self._exc_info_lock:
      if self._exc_info is not None:
        _, self._exception, self._traceback = self._exc_info

    self._state = RPC.FINISHING
    self._Callback()
    return True

  def _make_sync_call(self, service, call, request, response, request_id=None,
                      os_environ=None):
    """ A wrapper for MakeSyncCall that handles exceptions.

    Args:
      service: A string the specifies the API service.
      call: A string specifying the service method to call.
      request: A ProtocolMessage instance that specifies request properties.
      response: A ProtocolMessage instance that the response populates.
      request_id: A string specifying the request ID.
      os_environ: A dictionary containing the parent thread's environment.
    """
    if request_id is not None and hasattr(self.stub, '_SetRequestId'):
      self.stub._SetRequestId(request_id)

    if os_environ is not None:
      os.environ.update(os_environ)

    try:
      self.stub.MakeSyncCall(service, call, request, response)
    except Exception:
      # Store exception info so calling thread can access it.
      with self._exc_info_lock:
        self._exc_info = sys.exc_info()
