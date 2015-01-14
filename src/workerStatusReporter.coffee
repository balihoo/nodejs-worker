'use strict'
os = require 'os'
Promise = require 'bluebird'
dynamoAdapter = require './dynamoAdapter'

WORKER_STATUS_TABLE = 'fulfillment_worker_status'

now = ->
  return new Date().toISOString()

class WorkerStatusReporter
  constructor: (@instanceId, config) ->
    config.tableName = WORKER_STATUS_TABLE

    @key = { instance: @instanceId }
    @hostAddress = os.hostname()
    @domain = config.domain
    @name = config.name
    @version = config.version
    @specification =
      parameters: config.parameterSchema || {}
      result: config.resultSchema || {}

    @resolutionHistory = []

    @dynamoAdapter = new dynamoAdapter(config)

  init: ->
    return @dynamoAdapter.putItem
      instance: @instanceId
      hostAddress: os.hostname()
      domain: @domain
      activityName: @name
      activityVersion: @version
      specification: JSON.stringify(@specification)
      status: 'Starting'
      resolutionHistory: JSON.stringify(@resolutionHistory)
      start: now()
      last: now()
      
  updateStatus: (status) ->
    return @dynamoAdapter.updateItem @key,
      status: status
      last: now()

  addResult: (resolution, result) ->
    details = JSON.stringify result
      .substr 0, 30

    @resolutionHistory.push
      resolution: resolution,
      when: now(),
      details: details

    # Keep the last 20 only
    if @resolutionHistory.length > 20
      @resolutionHistory = @resolutionHistory.slice 1

    return @dynamoAdapter.updateItem @key,
      resolutionHistory: JSON.stringify(@resolutionHistory)
      last: now()

module.exports = WorkerStatusReporter