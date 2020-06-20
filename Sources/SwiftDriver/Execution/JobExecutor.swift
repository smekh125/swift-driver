//===--------------- JobExecutor.swift - Swift Job Execution --------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
import TSCBasic
import enum TSCUtility.Diagnostics

import Foundation
import Dispatch

/// Resolver for a job's argument template.
public struct ArgsResolver {
  /// The map of virtual path to the actual path.
  public var pathMapping: [VirtualPath: AbsolutePath]

  /// The file system used by the resolver.
  private let fileSystem: FileSystem

  /// Path to the directory that will contain the temporary files.
  private let temporaryDirectory: AbsolutePath

  public init(fileSystem: FileSystem) throws {
    self.pathMapping = [:]
    self.fileSystem = fileSystem
    self.temporaryDirectory = try withTemporaryDirectory(removeTreeOnDeinit: false) { path in
      // FIXME: TSC removes empty directories even when removeTreeOnDeinit is false. This seems like a bug.
      try fileSystem.writeFileContents(path.appending(component: ".keep-directory")) { $0 <<< "" }
      return path
    }
  }

  public func resolveArgumentList(for job: Job, forceResponseFiles: Bool) throws -> [String] {
    let (arguments, _) = try resolveArgumentList(for: job, forceResponseFiles: forceResponseFiles)
    return arguments
  }

  public func resolveArgumentList(for job: Job, forceResponseFiles: Bool) throws -> ([String], usingResponseFile: Bool) {
    let tool = try resolve(.path(job.tool))
    var arguments = [tool] + (try job.commandLine.map { try resolve($0) })
    let usingResponseFile = try createResponseFileIfNeeded(for: job, resolvedArguments: &arguments,
                                                           forceResponseFiles: forceResponseFiles)
    return (arguments, usingResponseFile)
  }

  /// Resolve the given argument.
  public func resolve(_ arg: Job.ArgTemplate) throws -> String {
    switch arg {
    case .flag(let flag):
      return flag

    case .path(let path):
      // Return the path from the temporary directory if this is a temporary file.
      if path.isTemporary {
        let actualPath = temporaryDirectory.appending(component: path.name)
        return actualPath.pathString
      }

      // If there was a path mapping, use it.
      if let actualPath = pathMapping[path] {
        return actualPath.pathString
      }

      // Otherwise, return the path.
      return path.name
    }
  }

  private func createResponseFileIfNeeded(for job: Job, resolvedArguments: inout [String], forceResponseFiles: Bool) throws -> Bool {
    if forceResponseFiles ||
      (job.supportsResponseFiles && !commandLineFitsWithinSystemLimits(path: resolvedArguments[0], args: resolvedArguments)) {
      assert(!forceResponseFiles || job.supportsResponseFiles,
             "Platform does not support response files for job: \(job)")
      // Match the integrated driver's behavior, which uses response file names of the form "arguments-[0-9a-zA-Z].resp".
      let responseFilePath = temporaryDirectory.appending(component: "arguments-\(abs(job.hashValue)).resp")
      try fileSystem.writeFileContents(responseFilePath) {
        $0 <<< resolvedArguments[1...].map{ $0.spm_shellEscaped() }.joined(separator: "\n")
      }
      resolvedArguments = [resolvedArguments[0], "@\(responseFilePath.pathString)"]
      return true
    }
    return false
  }

  /// Remove the temporary directory from disk.
  public func removeTemporaryDirectory() throws {
    _ = try FileManager.default.removeItem(atPath: temporaryDirectory.pathString)
  }
}

public protocol JobExecutorDelegate {
  /// Called when a job starts executing.
  func jobStarted(job: Job, arguments: [String], pid: Int)

  /// Called when a job finished.
  func jobFinished(job: Job, result: ProcessResult, pid: Int)

  /// Launch the process for given command line.
  ///
  /// This will be called on the execution queue.
  func launchProcess(for job: Job, arguments: [String], env: [String: String]) throws -> ProcessProtocol
}

extension JobExecutorDelegate {
  public func launchProcess(for job: Job, arguments: [String], env: [String: String]) throws -> ProcessProtocol {
    return try Process.launchProcess(arguments: arguments, env: env)
  }
}

public final class JobExecutor {

  /// The context required during job execution.
  struct Context {

    /// This contains mapping from an output to the index(in the jobs array) of the job that produces that output.
    let producerMap: [VirtualPath: Int]

    /// All the jobs being executed.
    let jobs: [Job]

    /// The resolver for argument template.
    let argsResolver: ArgsResolver

    /// The environment variables.
    let env: [String: String]

    /// The file system.
    let fileSystem: FileSystem

    /// The job executor delegate.
    let executorDelegate: JobExecutorDelegate

    /// Queue for executor delegate.
    let delegateQueue: DispatchQueue = DispatchQueue(label: "org.swift.driver.job-executor-delegate")

    /// Operation queue for executing tasks in parallel.
    let jobQueue: OperationQueue

    /// The process set to use when launching new processes.
    let processSet: ProcessSet?

    /// If true, always use response files to pass command line arguments.
    let forceResponseFiles: Bool

    /// The last time each input file was modified, recorded at the start of the build.
    public let recordedInputModificationDates: [TypedVirtualPath: Date]

    /// The diagnostics engine to use when reporting errors.
    let diagnosticsEngine: DiagnosticsEngine

    init(
      argsResolver: ArgsResolver,
      env: [String: String],
      fileSystem: FileSystem,
      producerMap: [VirtualPath: Int],
      jobs: [Job],
      executorDelegate: JobExecutorDelegate,
      jobQueue: OperationQueue,
      processSet: ProcessSet?,
      forceResponseFiles: Bool,
      recordedInputModificationDates: [TypedVirtualPath: Date],
      diagnosticsEngine: DiagnosticsEngine
    ) {
      self.producerMap = producerMap
      self.jobs = jobs
      self.argsResolver = argsResolver
      self.env = env
      self.fileSystem = fileSystem
      self.executorDelegate = executorDelegate
      self.jobQueue = jobQueue
      self.processSet = processSet
      self.forceResponseFiles = forceResponseFiles
      self.recordedInputModificationDates = recordedInputModificationDates
      self.diagnosticsEngine = diagnosticsEngine
    }
  }

  /// The list of jobs that we may need to run.
  let jobs: [Job]

  /// The argument resolver.
  let argsResolver: ArgsResolver

  /// The job executor delegate.
  let executorDelegate: JobExecutorDelegate

  /// The number of jobs to run in parallel.
  let numParallelJobs: Int

  /// The process set to use when launching new processes.
  let processSet: ProcessSet?

  /// If true, always use response files to pass command line arguments.
  let forceResponseFiles: Bool

  /// The last time each input file was modified, recorded at the start of the build.
  public let recordedInputModificationDates: [TypedVirtualPath: Date]

  /// The diagnostics engine to use when reporting errors.
  let diagnosticsEngine: DiagnosticsEngine

  public init(
    jobs: [Job],
    resolver: ArgsResolver,
    executorDelegate: JobExecutorDelegate,
    diagnosticsEngine: DiagnosticsEngine,
    numParallelJobs: Int? = nil,
    processSet: ProcessSet? = nil,
    forceResponseFiles: Bool = false,
    recordedInputModificationDates: [TypedVirtualPath: Date] = [:]
  ) {
    self.jobs = jobs
    self.argsResolver = resolver
    self.executorDelegate = executorDelegate
    self.diagnosticsEngine = diagnosticsEngine
    self.numParallelJobs = numParallelJobs ?? 1
    self.processSet = processSet
    self.forceResponseFiles = forceResponseFiles
    self.recordedInputModificationDates = recordedInputModificationDates
  }

  /// Execute all jobs.
  public func execute(env: [String: String], fileSystem: FileSystem) throws {
    let context = createContext(jobs, env: env, fileSystem: fileSystem)

    let delegate = JobExecutorBuildDelegate(context)
    let engine = LLBuildEngine(delegate: delegate)

    let result = try engine.build(key: ExecuteAllJobsRule.RuleKey())

    // Throw the stub error the build didn't finish successfully.
    if !result.success {
      throw Diagnostics.fatalError
    }
  }

  /// Create the context required during the execution.
  func createContext(_ jobs: [Job], env: [String: String], fileSystem: FileSystem) -> Context {
    var producerMap: [VirtualPath: Int] = [:]
    for (index, job) in jobs.enumerated() {
      for output in job.outputs {
        assert(!producerMap.keys.contains(output.file), "multiple producers for output \(output): \(job) \(producerMap[output.file]!)")
        producerMap[output.file] = index
      }
    }

    let jobQueue = OperationQueue()
    jobQueue.name = "org.swift.driver.job-execution"
    jobQueue.maxConcurrentOperationCount = numParallelJobs

    return Context(
      argsResolver: argsResolver,
      env: env,
      fileSystem: fileSystem,
      producerMap: producerMap,
      jobs: jobs,
      executorDelegate: executorDelegate,
      jobQueue: jobQueue,
      processSet: processSet,
      forceResponseFiles: forceResponseFiles,
      recordedInputModificationDates: recordedInputModificationDates,
      diagnosticsEngine: diagnosticsEngine
    )
  }
}

struct JobExecutorBuildDelegate: LLBuildEngineDelegate {

  let context: JobExecutor.Context

  init(_ context: JobExecutor.Context) {
    self.context = context
  }

  func lookupRule(rule: String, key: Key) -> Rule {
    switch rule {
    case ExecuteAllJobsRule.ruleName:
      return ExecuteAllJobsRule(key, jobs: context.jobs, fileSystem: context.fileSystem)
    case ExecuteJobRule.ruleName:
      return ExecuteJobRule(key, context: context)
    default:
      fatalError("Unknown rule \(rule)")
    }
  }
}

/// The build value for driver build tasks.
struct DriverBuildValue: LLBuildValue {
  enum Kind: String, Codable {
    case jobExecution
  }

  /// If the build value was a success.
  var success: Bool

  /// The kind of build value.
  var kind: Kind

  static func jobExecution(success: Bool) -> DriverBuildValue {
    return .init(success: success, kind: .jobExecution)
  }
}

class ExecuteAllJobsRule: LLBuildRule {
  struct RuleKey: LLBuildKey {
    typealias BuildValue = DriverBuildValue
    typealias BuildRule = ExecuteAllJobsRule
  }

  override class var ruleName: String { "\(ExecuteAllJobsRule.self)" }

  private let key: RuleKey
  private let jobs: [Job]

  /// True if any of the inputs had any error.
  private var allInputsSucceeded: Bool = true

  init(_ key: Key, jobs: [Job], fileSystem: FileSystem) {
    self.key = RuleKey(key)
    self.jobs = jobs
    super.init(fileSystem: fileSystem)
  }

  override func start(_ engine: LLTaskBuildEngine) {
    for index in jobs.indices {
      let key = ExecuteJobRule.RuleKey(index: index)
      engine.taskNeedsInput(key, inputID: index)
    }
  }

  override func isResultValid(_ priorValue: Value) -> Bool {
    return false
  }

  override func provideValue(_ engine: LLTaskBuildEngine, inputID: Int, value: Value) {
    do {
      let buildValue = try DriverBuildValue(value)
      allInputsSucceeded = allInputsSucceeded && buildValue.success
    } catch {
      allInputsSucceeded = false
    }
  }

  override func inputsAvailable(_ engine: LLTaskBuildEngine) {
    engine.taskIsComplete(DriverBuildValue.jobExecution(success: allInputsSucceeded))
  }
}

class ExecuteJobRule: LLBuildRule {
  struct RuleKey: LLBuildKey {
    typealias BuildValue = DriverBuildValue
    typealias BuildRule = ExecuteJobRule

    let index: Int
  }

  override class var ruleName: String { "\(ExecuteJobRule.self)" }

  private let key: RuleKey
  private let context: JobExecutor.Context

  /// True if any of the inputs had any error.
  private var allInputsSucceeded: Bool = true

  init(_ key: Key, context: JobExecutor.Context) {
    self.key = RuleKey(key)
    self.context = context
    super.init(fileSystem: context.fileSystem)
  }

  override func start(_ engine: LLTaskBuildEngine) {
    for (idx, input) in context.jobs[key.index].inputs.enumerated() {
      if let producingJobIndex = context.producerMap[input.file] {
        let key = ExecuteJobRule.RuleKey(index: producingJobIndex)
        engine.taskNeedsInput(key, inputID: idx)
      }
    }
  }

  override func isResultValid(_ priorValue: Value) -> Bool {
    return false
  }

  override func provideValue(_ engine: LLTaskBuildEngine, inputID: Int, value: Value) {
    do {
      let buildValue = try DriverBuildValue(value)
      allInputsSucceeded = allInputsSucceeded && buildValue.success
    } catch {
      allInputsSucceeded = false
    }
  }

  override func inputsAvailable(_ engine: LLTaskBuildEngine) {
    // Return early any of the input failed.
    guard allInputsSucceeded else {
      return engine.taskIsComplete(DriverBuildValue.jobExecution(success: false))
    }

    context.jobQueue.addOperation {
      self.executeJob(engine)
    }
  }

  private func executeJob(_ engine: LLTaskBuildEngine) {
    let context = self.context
    let resolver = context.argsResolver
    let job = context.jobs[key.index]
    let env = context.env.merging(job.extraEnvironment, uniquingKeysWith: { $1 })

    let value: DriverBuildValue
    var pid = 0
    do {
      let arguments: [String] = try resolver.resolveArgumentList(for: job,
                                                                 forceResponseFiles: context.forceResponseFiles)

      try job.verifyInputsNotModified(since: context.recordedInputModificationDates, fileSystem: engine.fileSystem)

      let process = try context.executorDelegate.launchProcess(
        for: job, arguments: arguments, env: env
      )
      pid = Int(process.processID)

      // Add it to the process set if it's a real process.
      if case let realProcess as TSCBasic.Process = process {
        try context.processSet?.add(realProcess)
      }

      // Inform the delegate.
      context.delegateQueue.async {
        context.executorDelegate.jobStarted(job: job, arguments: arguments, pid: pid)
      }

      let result = try process.waitUntilExit()
      let success = result.exitStatus == .terminated(code: 0)

      // Inform the delegate about job finishing.
      context.delegateQueue.async {
        context.executorDelegate.jobFinished(job: job, result: result, pid: pid)
      }

      value = .jobExecution(success: success)
    } catch {
      if error is DiagnosticData {
        context.diagnosticsEngine.emit(error)
      }
      context.delegateQueue.async {
        let result = ProcessResult(
          arguments: [],
          environment: env,
          exitStatus: .terminated(code: 1),
          output: Result.success([]),
          stderrOutput: Result.success([])
        )
        context.executorDelegate.jobFinished(job: job, result: result, pid: 0)
      }
      value = .jobExecution(success: false)
    }

    engine.taskIsComplete(value)
  }
}

extension Job: LLBuildValue { }
