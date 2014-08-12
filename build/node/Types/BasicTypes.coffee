module.exports = (HB)->
  # @see Engine.parse
  parser = {}
  execution_listener = []

  #
  # A generic interface to operations.
  #
  # An operation has the following methods:
  # _encode: encodes an operation (needed only if instance of this operation is sent).
  # execute: execute the effects of this operations. Good examples are Insert-type and AddName-type
  # val: in the case that the operation holds a value
  #
  # Furthermore an encodable operation has a parser.
  #
  class Operation

    #
    # @param {Object} uid A unique identifier. If uid is undefined, a new uid will be created.
    # @see HistoryBuffer.getNextOperationIdentifier
    #
    constructor: (uid)->
      if not uid?
        uid = HB.getNextOperationIdentifier()
      {
        'creator': @creator
        'op_number' : @op_number
      } = uid

    #
    # Add an event listener. It depends on the operation which events are supported.
    # @param {String} event Name of the event.
    # @param {Function} f f is executed in case the event fires.
    #
    on: (event, f)->
      @event_listeners ?= {}
      @event_listeners[event] ?= []
      @event_listeners[event].push f

    #
    # Fire an event.
    # TODO: Do something with timeouts. You don't want this to fire for every operation (e.g. insert).
    #
    callEvent: (event, args)->
      if @event_listeners[event]?
        for f in @event_listeners[event]
          f.call @, event, args

    #
    # Set the parent of this operation.
    #
    setParent: (o)->
      @parent = o

    #
    # Computes a unique identifier (uid) that identifies this operation.
    #
    getUid: ()->
      { 'creator': @creator, 'op_number': @op_number }

    #
    # @private
    # Notify the all the listeners.
    #
    execute: ()->
      @is_executed = true
      for l in execution_listener
        l @_encode()
      @

    #
    # @private
    # Operations may depend on other operations (linked lists, etc.).
    # The saveOperation and validateSavedOperations methods provide
    # an easy way to refer to these operations via an uid or object reference.
    #
    # For example: We can create a new Delete operation that deletes the operation $o like this
    #     - var d = new Delete(uid, $o);   or
    #     - var d = new Delete(uid, $o.getUid());
    # Either way we want to access $o via d.deletes. In the second case validateSavedOperations must be called first.
    #
    # @overload saveOperation(name, op_uid)
    #   @param {String} name The name of the operation. After validating (with validateSavedOperations) the instantiated operation will be accessible via this[name].
    #   @param {Object} op_uid A uid that refers to an operation
    # @overload saveOperation(name, op)
    #   @param {String} name The name of the operation. After calling this function op is accessible via this[name].
    #   @param {Operation} op An Operation object
    #
    saveOperation: (name, op)->

      #
      # Every instance of $Operation must have an $execute function.
      # We use duck-typing to check if op is instantiated since there
      # could exist multiple classes of $Operation
      #
      if op?.execute?
        # is instantiated
        @[name] = op
      else if op?
        # not initialized. Do it when calling $validateSavedOperations()
        @unchecked ?= {}
        @unchecked[name] = op

    #
    # @private
    # After calling this function all not instantiated operations will be accessible.
    # @see Operation.saveOperation
    #
    # @return [Boolean] Whether it was possible to instantiate all operations.
    #
    validateSavedOperations: ()->
      uninstantiated = {}
      success = @
      for name, op_uid of @unchecked
        op = HB.getOperation op_uid
        if op
          @[name] = op
        else
          uninstantiated[name] = op_uid
          success = false
      delete @unchecked
      if not success
        @unchecked = uninstantiated
      success



  #
  # A simple Delete-type operation that deletes an Insert-type operation.
  #
  class Delete extends Operation

    #
    # @param {Object} uid A unique identifier. If uid is undefined, a new uid will be created.
    # @param {Object} deletes UID or reference of the operation that this to be deleted.
    #
    constructor: (uid, deletes)->
      @saveOperation 'deletes', deletes
      super uid

    #
    # @private
    # Convert all relevant information of this operation to the json-format.
    # This result can be sent to other clients.
    #
    _encode: ()->
      {
        'type': "Delete"
        'uid': @getUid()
        'deletes': @deletes.getUid()
      }

    #
    # @private
    # Apply the deletion.
    #
    execute: ()->
      if @validateSavedOperations()
        @deletes.applyDelete @
        super
        @
      else
        false

  #
  # Define how to parse Delete operations.
  #
  parser['Delete'] = (o)->
    {
      'uid' : uid
      'deletes': deletes_uid
    } = o
    new Delete uid, deletes_uid

  #
  # A simple insert-type operation.
  #
  # An insert operation is always positioned between two other insert operations.
  # Internally this is realized as associative lists, whereby each insert operation has a predecessor and a successor.
  # For the sake of efficiency we maintain two lists:
  #   - The short-list (abbrev. sl) maintains only the operations that are not deleted
  #   - The complete-list (abbrev. cl) maintains all operations
  #
  class Insert extends Operation

    #
    # @param {Object} uid A unique identifier. If uid is undefined, a new uid will be created.
    # @param {Operation} prev_cl The predecessor of this operation in the complete-list (cl)
    # @param {Operation} next_cl The successor of this operation in the complete-list (cl)
    #
    # @see HistoryBuffer.getNextOperationIdentifier
    #
    constructor: (uid, prev_cl, next_cl, origin)->
      @saveOperation 'prev_cl', prev_cl
      @saveOperation 'next_cl', next_cl
      if origin?
        @saveOperation 'origin', origin
      else
        @saveOperation 'origin', prev_cl
      super uid

    #
    # @private
    #
    applyDelete: (o)->
      @deleted_by ?= []
      @deleted_by.push o

    #
    # If isDeleted() is true this operation won't be maintained in the sl
    #
    isDeleted: ()->
      @deleted_by?.length > 0

    #
    # @private
    # The amount of positions that $this operation was moved to the right.
    #
    getDistanceToOrigin: ()->
      d = 0
      o = @prev_cl
      while true
        if @origin is o
          break
        d++
        #TODO: delete this
        if @ is @prev_cl
          throw new Error "this should not happen ;) "
        o = o.prev_cl
      d

    #
    # @private
    # Update the short list
    # TODO (Unused)
    update_sl: ()->
      o = @prev_cl
      update: (dest_cl,dest_sl)->
        while true
          if o.isDeleted()
            o = o[dest_cl]
          else
            @[dest_sl] = o

            break
      update "prev_cl", "prev_sl"
      update "next_cl", "prev_sl"



    #
    # @private
    # Include this operation in the associative lists.
    #
    execute: ()->
      if @is_executed?
        return @
      if not @validateSavedOperations()
        return false
      else
        if @prev_cl?.validateSavedOperations() and @next_cl?.validateSavedOperations() and @prev_cl.next_cl isnt @
          distance_to_origin = 0
          o = @prev_cl.next_cl
          i = 0
          # $this has to find a unique position between origin and the next known character
          # case 1: $origin equals $o.origin: the $creator parameter decides if left or right
          #         let $OL= [o1,o2,o3,o4], whereby $this is to be inserted between o1 and o4
          #         o2,o3 and o4 origin is 1 (the position of o2)
          #         there is the case that $this.creator < o2.creator, but o3.creator < $this.creator
          #         then o2 knows o3. Since on another client $OL could be [o1,o3,o4] the problem is complex
          #         therefore $this would be always to the right of o3
          # case 2: $origin < $o.origin
          #         if current $this insert_position > $o origin: $this ins
          #         else $insert_position will not change (maybe we encounter case 1 later, then this will be to the right of $o)
          # case 3: $origin > $o.origin
          #         $this insert_position is to the left of $o (forever!)
          while true
            if not o?
              # TODO: Debugging
              console.log JSON.stringify @prev_cl.getUid()
              console.log JSON.stringify @next_cl.getUid()
            if o isnt @next_cl
              # $o happened concurrently
              if o.getDistanceToOrigin() is i
                # case 1
                if o.creator < @creator
                  @prev_cl = o
                  distance_to_origin = i + 1
                else
                  # nop
              else if o.getDistanceToOrigin() < i
                # case 2
                if i - distance_to_origin <= o.getDistanceToOrigin()
                  @prev_cl = o
                  distance_to_origin = i + 1
                else
                  #nop
              else
                # case 3
                break
              i++
              o = o.next_cl
            else
              # $this knows that $o exists,
              break
          # now reconnect everything
          @next_cl = @prev_cl.next_cl
          @prev_cl.next_cl = @
          @next_cl.prev_cl = @
        super # notify the execution_listeners
        @

  #
  # Defines an object that is cannot be changed. You can use this to set an immutable string, or a number.
  #
  class ImmutableObject extends Insert

    #
    # @param {Object} uid A unique identifier. If uid is undefined, a new uid will be created.
    # @param {Object} content
    #
    constructor: (uid, @content, prev, next, origin)->
      super uid, prev, next, origin

    #
    # @return [String] The content of this operation.
    #
    val : ()->
      @content

    #
    # Encode this operation in such a way that it can be parsed by remote peers.
    #
    _encode: ()->
      json = {
        'type': "ImmutableObject"
        'uid' : @getUid()
        'content' : @content
      }
      if @prev_cl?
        json['prev'] = @prev_cl.getUid()
      if @next_cl?
        json['next'] = @next_cl.getUid()
      if @origin? and @origin isnt @prev_cl
        json["origin"] = @origin.getUid()
      json

  parser['ImmutableObject'] = (json)->
    {
      'uid' : uid
      'content' : content
      'prev': prev
      'next': next
      'origin' : origin
    } = json
    new ImmutableObject uid, content, prev, next, origin

  #
  # A delimiter is placed at the end and at the beginning of the associative lists.
  # This is necessary in order to have a beginning and an end even if the content
  # of the Engine is empty.
  #
  class Delimiter extends Operation
    #
    # @param {Object} uid A unique identifier. If uid is undefined, a new uid will be created.
    # @param {Operation} prev_cl The predecessor of this operation in the complete-list (cl)
    # @param {Operation} next_cl The successor of this operation in the complete-list (cl)
    #
    # @see HistoryBuffer.getNextOperationIdentifier
    #
    constructor: (uid, prev_cl, next_cl, origin)->
      @saveOperation 'prev_cl', prev_cl
      @saveOperation 'next_cl', next_cl
      @saveOperation 'origin', prev_cl
      super uid

    #
    # If isDeleted() is true this operation won't be maintained in the sl
    #
    isDeleted: ()->
      false

    #
    # @private
    #
    execute: ()->
      if @unchecked?['next_cl']?
        super
      else if @unchecked?['prev_cl']
        if @validateSavedOperations()
          if @prev_cl.next_cl?
            throw new Error "Probably duplicated operations"
          @prev_cl.next_cl = @
          delete @prev_cl.unchecked.next_cl
          super
        else
          false
      else if @prev_cl? and not @prev_cl.next_cl?
        delete @prev_cl.unchecked.next_cl
        @prev_cl.next_cl = @
      else if @prev_cl? or @next_cl?
        super
      else
        throw new Error "Delimiter is unsufficient defined!"

    #
    # @private
    #
    _encode: ()->
      {
        'type' : "Delimiter"
        'uid' : @getUid()
        'prev' : @prev_cl?.getUid()
        'next' : @next_cl?.getUid()
      }

  parser['Delimiter'] = (json)->
    {
    'uid' : uid
    'prev' : prev
    'next' : next
    } = json
    new Delimiter uid, prev, next

  # This is what this module exports after initializing it with the HistoryBuffer
  {
    'types' :
      'Delete' : Delete
      'Insert' : Insert
      'Delimiter': Delimiter
      'Operation': Operation
      'ImmutableObject' : ImmutableObject
    'parser' : parser
    'execution_listener' : execution_listener
  }




