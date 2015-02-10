//
//  PlugConnection.swift
//  Plug
//
//  Created by Ben Gottlieb on 2/9/15.
//  Copyright (c) 2015 Stand Alone, inc. All rights reserved.
//

import Foundation



extension Plug {
	public class Connection: NSObject {
		enum State: String, Printable { case NotStarted = "Not Started", Running = "Running", Suspended = "Suspended", Completed = "Completed", Canceled = "Canceled"
			var description: String { return self.rawValue }
		}
		
		let method: Method
		let URL: NSURL
		var state: State = .NotStarted
		var request: NSURLRequest?
		let completionQueue: NSOperationQueue
		let parameters: Plug.Parameters
		var headers: [String: String]?
		
		lazy var task: NSURLSessionTask = {
			self.task = Plug.defaultManager.session.downloadTaskWithRequest(self.request ?? self.defaultRequest, completionHandler: nil)
			
			Plug.defaultManager.registerConnection(self)
			return self.task
		}()
		
		init?(method meth: Method = .GET, URL url: NSURLConvertible, parameters params: Plug.Parameters? = nil) {
			completionQueue = NSOperationQueue()
			completionQueue.suspended = true
			
			parameters = params ?? .None
			
			method = parameters.normalizeMethod(meth)
			URL = url.URL!
			
			super.init()
			if url.URL == nil { return nil }
			if Plug.defaultManager.autostartConnections { self.start() }
		}
		
		var resultsError: NSError?
		var resultsURL: NSURL?
		var resultsData: NSData? { return (self.resultsURL == nil) ? nil : NSData(contentsOfURL: self.resultsURL!) }
		
		func completedWithError(error: NSError) {
			self.resultsError = error
			self.completionQueue.suspended = false
		}
		
		func completedDownloadingToURL(location: NSURL) {
			var filename = "Plug-temp-\(location.lastPathComponent!.hash).tmp"
			var error: NSError?
			
			self.resultsURL = Plug.defaultManager.temporaryDirectoryURL.URLByAppendingPathComponent(filename)
			NSFileManager.defaultManager().moveItemAtURL(location, toURL: self.resultsURL!, error: &error)
			
			self.completionQueue.suspended = false
		}
		
		var defaultRequest: NSURLRequest {
			var urlString = self.URL.absoluteString! + self.parameters.URLString
			var request = NSMutableURLRequest(URL: NSURL(string: urlString)!)
			
			request.allHTTPHeaderFields = self.headers ?? Plug.defaultManager.defaultHeaders
			request.HTTPMethod = self.method.rawValue
			request.HTTPBody = self.parameters.bodyData
			
			return request
		}
	}
	
	var noopConnection: Plug.Connection { return Plug.Connection(URL: "about:blank")! }
}

extension Plug.Connection {
	public func completion(completion: (NSData) -> Void, queue: NSOperationQueue? = nil) -> Self {
		self.completionQueue.addOperationWithBlock {
			(queue ?? NSOperationQueue.mainQueue()).addOperationWithBlock {
				if let data = self.resultsData { completion(data) }
			}
		}
		return self
	}

	public func error(completion: (NSError) -> Void, queue: NSOperationQueue? = nil) -> Self {
		self.completionQueue.addOperationWithBlock {
			(queue ?? NSOperationQueue.mainQueue()).addOperationWithBlock {
				if let error = self.resultsError { completion(error) }
			}
		}
		return self
	}
}

extension Plug.Connection: Printable {
	public override var description: String {
		var request = self.request ?? self.defaultRequest
		var string = "\(self.method) \(request.URL.absoluteString!) \(self.parameters): \(self.state)"
		
		return string
	}
}

extension Plug.Connection {		//actions
	public func start() {
		assert(state == .NotStarted, "Trying to start an already started connection")
		self.state = .Running
		self.task.resume()
	}
	
	public func suspend() {
		self.state = .Suspended
		self.task.suspend()
	}
	
	public func resume() {
		self.state = .Running
		self.task.resume()
	}
	
	public func cancel() {
		self.state = .Canceled
		self.task.cancel()
	}
}