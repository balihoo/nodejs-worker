'use strict'
nodeUuid = require 'node-uuid'
Promise = require 'bluebird'
error = require './error'
SwfAdapter = require './swfAdapter'
S3Adapter = require './s3Adapter'
WorkerStatusReporter = require './workerStatusReporter'
dataZipper = require './dataZipper'
activityStatus = require './activityStatus'
validate = require './validate'
ActivityProgressListener = require './activityProgressListener'

class FulfillmentWorker
  constructor: (config) ->
    validate.validateConfig(config, ['region', 'domain', 'name', 'version'])

    @uuid = nodeUuid.v4()
    config.apiVersion = '2015-01-07'
    @name = config.name
    @version = config.version
    @swfAdapter = new SwfAdapter config
    s3Adapter = new S3Adapter config
    @dataZipper = new dataZipper.DataZipper s3Adapter
    @workerStatusReporter = new WorkerStatusReporter @uuid, config
    @keepPolling = true
    @completedTasks = 0
    @canceledTasks = 0
    @failedTasks = 0
    @logger = config.logger or console

  workAsync: (workerFunc) ->
    handleError = (err) =>
      err.workerName = @name
      err.workerVersion = @version
      @logger.error err

      status = activityStatus.error

      if err instanceof error.CancelTaskError
        status = activityStatus.defer
      else if err instanceof error.FailTaskError
        status = activityStatus.fatal

      @dataZipper.deliver
        status: status
        notes: []
        reason: err.message
        result: err.message
        trace: err.stack?.split("\n") or []
      .then (details) =>
        if err instanceof error.CancelTaskError
          @canceledTasks++
          @swfAdapter.cancelTask @taskToken, details
          @workerStatusReporter.addResult 'Canceled', details
        else
          @failedTasks++
          @swfAdapter.failTask @taskToken, details
          @workerStatusReporter.addResult 'Failed', details

    handleTask = (task) =>
      @taskToken = task?.taskToken

      if @taskToken
        # Decompress the input if needed
        @dataZipper.receive task.input
        .then (decompressedInput) =>
          # Parse the input into an object and do the work
          input = JSON.parse decompressedInput

          # create context
          recordHeartbeat = (details) =>
            @swfAdapter.recordHeartbeat @taskToken, details

          createProgressListener = (interval, streamOpts) ->
            new ActivityProgressListener interval, recordHeartbeat, streamOpts

          context =
            recordHeartbeat: recordHeartbeat
            createProgressListener: createProgressListener
            workflowExecution: task.workflowExecution

          ###
          Wrap the worker call in Promise.resolve.  This allows workerFunc to return a simple value,
          a bluebird promise, or a promise from another A+ promise library.
          ###
          Promise.resolve workerFunc(input, context)

        .then (workResult) ->
          status: activityStatus.success
          result: workResult
      else
        # No work to be done
        Promise.resolve()

    pollForWork = =>
      @workerStatusReporter.updateStatus "Polling #{@completedTasks}:#{@failedTasks}:#{@canceledTasks}"

      @swfAdapter.pollForActivityTaskAsync()
      .then handleTask
      .then @dataZipper.deliver
      .then (workResult) =>
        if (workResult)
          @completedTasks++
          @swfAdapter.respondWithWorkResult @taskToken, workResult
          @workerStatusReporter.addResult 'Completed', workResult
      .catch handleError
      .finally =>
        if @keepPolling
          pollForWork()

    @swfAdapter.ensureActivityTypeRegistered()
    .then =>
      @workerStatusReporter.init()
    .then pollForWork

  stop: ->
    @keepPolling = false
    @workerStatusReporter.updateStatus 'Stopping...'

module.exports = FulfillmentWorker

module.exports.S3Adapter = S3Adapter
module.exports.dataZipper = dataZipper
