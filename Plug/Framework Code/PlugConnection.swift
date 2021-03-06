//
//  PlugConnection.swift
//  Plug
//
//  Created by Ben Gottlieb on 2/9/15.
//  Copyright (c) 2015 Stand Alone, inc. All rights reserved.
//

import Foundation

extension Plug {
	public class Connection: NSObject, Equatable {
		public enum Persistence { case Transient, PersistRequest, Persistent(PersistenceInfo)
			public var isPersistent: Bool {
				switch (self) {
				case .Transient: return false
				default: return true
				}
			}
			public var persistentDelegate: PlugPersistentDelegate? { return PersistenceManager.defaultManager.delegateForPersistenceInfo(self.persistentInfo) }
			
			public var persistentInfo: PersistenceInfo? {
				switch (self) {
				case .Persistent(let info): return info
				default: return nil
				}
			}
			
			public var JSONValue: AnyObject { return self.persistentInfo?.JSONValue ?? [] }
				
		}
		public let persistence: Persistence
		
		public enum State: String, Printable { case Waiting = "Waiting", Queued = "Queued", Running = "Running", Suspended = "Suspended", Completed = "Completed", Canceled = "Canceled", CompletedWithError = "Completed with Error"
			public var description: String { return self.rawValue }
			public var isRunning: Bool { return self == .Running }
			public var hasStarted: Bool { return self != .Waiting && self != .Queued }
		}
		public var state: State = .Waiting {
			didSet {
				if self.state == oldValue { return }
				#if os(iOS)
					if oldValue == .Running { NetworkActivityIndicator.decrement() }
					if self.state.isRunning { NetworkActivityIndicator.increment() }
				#endif
			}
		}
		
		public var cachingPolicy: NSURLRequestCachePolicy = .ReloadIgnoringLocalCacheData
		public var response: NSURLResponse?
		public var statusCode: Int?
		public var completionQueue: NSOperationQueue?
		
		public let method: Method
		public let URL: NSURL
		public var downloadToFile = false
		public var request: NSURLRequest?
		public let requestQueue: NSOperationQueue
		public let parameters: Plug.Parameters
		public var headers: Plug.Headers?
		public var startedAt: NSDate?
		public var completedAt: NSDate?
		public let channel: Plug.Channel
		public var elapsedTime: NSTimeInterval {
			if let startedAt = self.startedAt {
				if let completedAt = self.completedAt {
					return abs(startedAt.timeIntervalSinceDate(completedAt))
				} else {
					return abs(startedAt.timeIntervalSinceNow)
				}
			}
			return 0
		}
		public func addHeader(header: Plug.Header) {
			if self.headers == nil { self.headers = Plug.defaultManager.defaultHeaders }
			self.headers?.append(header)
		}
		
		
		public init?(method meth: Method = .GET, URL url: NSURLConvertible, parameters params: Plug.Parameters? = nil, persistence persist: Persistence = .Transient, channel chn: Plug.Channel = Plug.Channel.defaultChannel) {
			requestQueue = NSOperationQueue()
			requestQueue.maxConcurrentOperationCount = 1
			requestQueue.suspended = true
			
			persistence = persist
			parameters = params ?? .None
			channel = chn
			
			method = parameters.normalizeMethod(meth)
			URL = url.URL ?? NSURL()
			
			super.init()
			if url.URL == nil {
				println("Unable to create a connection with URL: \(url)")

				return nil
			}
			if let header = self.parameters.contentTypeHeader { self.addHeader(header) }

			if Plug.defaultManager.autostartConnections {
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(1.0 * Double(NSEC_PER_SEC))), dispatch_get_main_queue()) {
					self.queue()
				}
			}
		}
		
		var task: NSURLSessionTask?
		func generateTask() -> NSURLSessionTask {
			if self.downloadToFile {
				return Plug.defaultManager.session.downloadTaskWithRequest(self.request ?? self.defaultRequest, completionHandler: nil)
			} else {
				return Plug.defaultManager.session.dataTaskWithRequest(self.request ?? self.defaultRequest, completionHandler: { data, response, error in
					if let httpResponse = response as? NSHTTPURLResponse { self.statusCode = httpResponse.statusCode }
					self.response = response
					self.resultsError = error ?? response.error
					if error != nil && error!.code == -1005 {
						println("++++++++ Simulator comms issue, please restart the sim. ++++++++")
					}
					if error == nil || data.length > 0 {
						self.resultsData = data
					}
					self.complete((error == nil) ? .Completed : .CompletedWithError)
				})
			}
		}
		
		var resultsError: NSError?
		var resultsURL: NSURL? { didSet { if let url = self.resultsURL { self.resultsData = NSData(contentsOfURL: url) } } }
		var resultsData: NSData?
		
		func failedWithError(error: NSError?) {
			if error != nil && error!.code == -1005 {
				println("++++++++ Simulator comms issue, please restart the sim. ++++++++")
			}
			self.response = self.task?.response
			if let httpResponse = self.response as? NSHTTPURLResponse { self.statusCode = httpResponse.statusCode }
			self.resultsError = error ?? self.task?.response?.error
			self.complete(.CompletedWithError)
		}

		func completedDownloadingToURL(location: NSURL) {
			var filename = "Plug-temp-\(location.lastPathComponent!.hash).tmp"
			var error: NSError?
			
			self.response = self.task?.response
			if let httpResponse = self.response as? NSHTTPURLResponse { self.statusCode = httpResponse.statusCode }
			self.resultsURL = Plug.defaultManager.temporaryDirectoryURL.URLByAppendingPathComponent(filename)
			NSFileManager.defaultManager().moveItemAtURL(location, toURL: self.resultsURL!, error: &error)
			
			self.complete(.Completed)
		}
		
		var defaultRequest: NSURLRequest {
			var urlString = self.URL.absoluteString! + self.parameters.URLString
			var request = NSMutableURLRequest(URL: NSURL(string: urlString)!)
			
			request.allHTTPHeaderFields = (self.headers ?? Plug.defaultManager.defaultHeaders).dictionary
			request.HTTPMethod = self.method.rawValue
			request.HTTPBody = self.parameters.bodyData
			request.cachePolicy = self.cachingPolicy
			
			return request
		}
		public func notifyPersistentDelegateOfCompletion() {
			self.persistence.persistentDelegate?.connectionCompleted(self, info: self.persistence.persistentInfo)
		}
	}

	var noopConnection: Plug.Connection { return Plug.Connection(URL: "about:blank")! }
}

extension Plug.Connection {
	public func completion(completion: (NSData) -> Void) -> Self {
		self.requestQueue.addOperationWithBlock {
			(self.completionQueue ?? NSOperationQueue.mainQueue()).addOperationWithBlock {
				if let data = self.resultsData { completion(data) }
			}
		}
		return self
	}

	public func error(completion: (NSError) -> Void) -> Self {
		self.requestQueue.addOperationWithBlock {
			(self.completionQueue ?? NSOperationQueue.mainQueue()).addOperationWithBlock {
				if let error = self.resultsError { completion(error) }
			}
		}
		return self
	}
}



extension Plug.Connection: Printable {
	public override var description: String { return self.detailedDescription() }

	public func detailedDescription(includeDelimiters: Bool = true) -> String {
		var request = self.generateTask().originalRequest
		var URL = "[no URL]"
		if let url = request.URL { URL = url.description }
		var string = includeDelimiters ? "\n▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽▽\n" : ""
		var durationString = self.elapsedTime > 0.0 ? String(format: "%.2f", self.elapsedTime) + " sec elapsed" : ""
		
		string += "\(self.method) \(URL) \(self.parameters) \(durationString) 〘\(self.state) on \(self.channel.name)〙"
		if let status = self.statusCode { string += " -> \(status)" }

		
		for (label, header) in (self.headers?.dictionary ?? [:]) {
			string += "\n   \(label): \(header)"
		}
		
		if count(self.parameters.description) > 0 {
			string += "\n Parameters: " + self.parameters.description
		}
		
		if let response = self.response as? NSHTTPURLResponse {
			string += "\n╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍ [Response] ╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍"
			
			for (label, header) in (response.allHeaderFields as! [String: String]) {
				string += "\n   \(label): \(header)"
			}
		}
		if let data = self.resultsData {
			var error: NSError?
			var json: AnyObject? = NSJSONSerialization.JSONObjectWithData(data, options: nil, error: &error)

			string += "\n╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍ [Body] ╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍╍\n"

			if let json = json as? NSObject {
				string += json.description
			} else {
				string += (NSString(data: data, encoding: NSUTF8StringEncoding)?.description ?? "--unable to parse data as! UTF8--")
			}
		}
		if !string.hasSuffix("\n") { string += "\n" }
		if includeDelimiters { string +=       "△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△△\n" }
		return string
	}
	
	public func logErrorToFile(label: String = "") {
		let errorsDir = "~/Library/Plug-Errors".stringByExpandingTildeInPath
		var code = self.statusCode ?? 0
		var seconds = Int(NSDate().timeIntervalSinceReferenceDate)
		var host = ""
		if let url = request?.URL { host = url.host ?? "" }
		var filename = "\(code) \(host) \(seconds).txt".stringByReplacingOccurrencesOfString(":", withString: "").stringByReplacingOccurrencesOfString("/", withString: "_")
		if label != "" { filename = label + "- " + filename }
		var filepath = errorsDir.stringByAppendingPathComponent(filename)
		
		NSFileManager.defaultManager().createDirectoryAtPath(errorsDir, withIntermediateDirectories: true, attributes: nil, error: nil)
		
		var contents = self.detailedDescription(includeDelimiters: false)
		
		contents.writeToFile(filepath, atomically: true, encoding: NSUTF8StringEncoding, error: nil)
		
	}

	public func log() {
		NSLog("\(self.description)")
	}
	
}

extension Plug.Connection {		//actions
	public func queue() {
		if (self.state != .Waiting) { return }
		self.channel.enqueue(self)
	}
	
	public func start() {
		if (state != .Waiting && state != .Queued) { return }
		
		self.channel.connectionStarted(self)
		self.state = .Running
		self.task = self.generateTask()
		Plug.defaultManager.registerConnection(self)
		self.task!.resume()
		self.startedAt = NSDate()
		self.requestQueue.addOperationWithBlock({ self.notifyPersistentDelegateOfCompletion() })
	}
	
	public func suspend() {
		if self.state != .Running { return }
		self.channel.connectionStopped(self)
		self.state = .Suspended
		self.task?.suspend()
	}
	
	public func resume() {
		if self.state != .Suspended { return }
		self.channel.connectionStarted(self)
		self.state = .Running
		self.task?.resume()
	}
	
	public func cancel() {
		self.channel.connectionStopped(self)
		self.state = .Canceled
		self.task?.cancel()
		NSNotificationCenter.defaultCenter().postNotificationName(Plug.notifications.connectionCancelled, object: self)
	}
	
	func complete(state: State) {
		self.state = state
		self.completedAt = NSDate()
		Plug.defaultManager.unregisterConnection(self)
		self.channel.connectionStopped(self)
		self.channel.dequeue(self)
		self.requestQueue.suspended = false
		if self.state == .Completed {
			NSNotificationCenter.defaultCenter().postNotificationName(Plug.notifications.connectionCompleted, object: self)
		} else {
			NSNotificationCenter.defaultCenter().postNotificationName(Plug.notifications.connectionFailed, object: self, userInfo: (self.resultsError != nil) ? ["error": self.resultsError!] : nil)
		}
	}
}

extension NSURLRequest: Printable {
	public override var description: String {
		var str = (self.HTTPMethod ?? "[no method]") + " " + "\(self.URL)"
		
		for (label, value) in (self.allHTTPHeaderFields as! [String: String]) {
			str += "\n\t" + label + ": " + value
		}
		
		if let data = self.HTTPBody {
			var body = NSString(data: data, encoding: NSUTF8StringEncoding)
			str += "\n" + (body?.description ?? "[unconvertible body: \(data.length) bytes]")
		}
		
		return str
	}
}

public func ==(lhs: Plug.Connection, rhs: Plug.Connection) -> Bool {
	return lhs === rhs
}

