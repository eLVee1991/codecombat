async = require 'async'
Handler = require '../commons/Handler'
Course = require './Course'
CourseInstance = require './CourseInstance'
LevelSession = require '../levels/sessions/LevelSession'
LevelSessionHandler = require '../levels/sessions/level_session_handler'
Prepaid = require '../prepaids/Prepaid'
PrepaidHandler = require '../prepaids/prepaid_handler'
User = require '../users/User'
UserHandler = require '../users/user_handler'
utils = require '../../app/core/utils'

CourseInstanceHandler = class CourseInstanceHandler extends Handler
  modelClass: CourseInstance
  jsonSchema: require '../../app/schemas/models/course_instance.schema'
  allowedMethods: ['GET', 'POST', 'PUT', 'DELETE']

  logError: (user, msg) ->
    console.warn "Course instance error: #{user.get('slug')} (#{user._id}): '#{msg}'"

  hasAccess: (req) ->
    req.method in @allowedMethods or req.user?.isAdmin()

  hasAccessToDocument: (req, document, method=null) ->
    return true if document?.get('ownerID')?.equals(req.user?.get('_id'))
    return true if req.method is 'GET' and _.find document?.get('members'), (a) -> a.equals(req.user?.get('_id'))
    req.user?.isAdmin()

  getByRelationship: (req, res, args...) ->
    relationship = args[1]
    return @createAPI(req, res) if relationship is 'create'
    return @getLevelSessionsAPI(req, res, args[0]) if args[1] is 'level_sessions'
    return @getMembersAPI(req, res, args[0]) if args[1] is 'members'
    super arguments...

  createAPI: (req, res) ->
    return @sendUnauthorizedError(res) if not req.user? or req.user?.isAnonymous()

    # Required Input
    seats = req.body.seats
    unless seats > 0
      @logError(req.user, 'Course create API missing required seats count')
      return @sendBadInputError(res, 'Missing required seats count')
    # Optional - unspecified means create instances for all courses
    courseID = req.body.courseID
    # Optional
    name = req.body.name
    # Optional - as long as course(s) are all free
    stripeToken = req.body.stripe?.token

    query = if courseID? then {_id: courseID} else {}
    Course.find query, (err, courses) =>
      if err
        @logError(user, "Find courses error: #{JSON.stringify(err)}")
        return done(err)

      PrepaidHandler.purchasePrepaidCourse req.user, courses, seats, new Date().getTime(), stripeToken, (err, prepaid) =>
        if err
          @logError(req.user, err)
          return @sendBadInputError(res, err) if err is 'Missing required Stripe token'
          return @sendDatabaseError(res, err)

        courseInstances = []
        makeCreateInstanceFn = (course, name, prepaid) =>
          (done) =>
            @createInstance req, course, name, prepaid, (err, newInstance)=>
              courseInstances.push newInstance unless err
              done(err)
        tasks = (makeCreateInstanceFn(course, name, prepaid) for course in courses)
        async.parallel tasks, (err, results) =>
          return @sendDatabaseError(res, err) if err
          @sendCreated(res, courseInstances)

  createInstance: (req, course, name, prepaid, done) =>
    courseInstance = new CourseInstance
      courseID: course.get('_id')
      members: [req.user.get('_id')]
      name: name
      ownerID: req.user.get('_id')
      prepaidID: prepaid.get('_id')
    courseInstance.save (err, newInstance) =>
      done(err, newInstance)

  getLevelSessionsAPI: (req, res, courseInstanceID) ->
    CourseInstance.findById courseInstanceID, (err, courseInstance) =>
      return @sendDatabaseError(res, err) if err
      return @sendNotFoundError(res) unless courseInstance
      memberIDs = _.map courseInstance.get('members') ? [], (memberID) -> memberID.toHexString?() or memberID
      LevelSession.find {creator: {$in: memberIDs}}, (err, documents) =>
        return @sendDatabaseError(res, err) if err?
        cleandocs = (LevelSessionHandler.formatEntity(req, doc) for doc in documents)
        @sendSuccess(res, cleandocs)

  getMembersAPI: (req, res, courseInstanceID) ->
    CourseInstance.findById courseInstanceID, (err, courseInstance) =>
      return @sendDatabaseError(res, err) if err
      return @sendNotFoundError(res) unless courseInstance
      memberIDs = courseInstance.get('members') ? []
      User.find {_id: {$in: memberIDs}}, (err, users) =>
        return @sendDatabaseError(res, err) if err
        cleandocs = (UserHandler.formatEntity(req, doc) for doc in users)
        @sendSuccess(res, cleandocs)

module.exports = new CourseInstanceHandler()
