class AnsiblePlaybookProcess

   RIGHTS = {
      'run' => 1,
      'delete' => 2
   }

   attr_reader    :method, :id
   attr_accessor  :body

   def initialize id:nil, data:{'action' => {}}, user:nil
      @user = user # Need this to check permissions later
      if id.nil? then # If id is not given - new Playbook will be created
         @params = IONe.GetAnsiblePlaybook(data['playbook_id'])
         @permissions = Array.new(3) do | uma |
            ansible_check_permissions(@params, @user, uma)
         end
         raise NoAccessError.new(0) unless @permissions[0] # Custom error if user is not in oneadmin group
         @user.info! # Retrieve object body
         @id = id = IONe.AnsiblePlaybookToProcess(data['playbook_id'], @user.id, data['hosts'], data['vars'], data['comment']) # Save id of new playbook
      else # If id is given getting existing playbook
         # Params from OpenNebula are always in {"action" => {"perform" => <%method name%>, "params" => <%method params%>}} form
         # So here initializer saves method and params to object
         @method, @params = data['action']['perform'], data['action']['params']
         @body = IONe.GetAnsiblePlaybookProcess(@id = id) # Getting Playbook in hash form
         @permissions = Array.new(3) do |uma|
            ansible_check_permissions({ 'uid' => @body['uid'], 'extra_data' => { 'PERMISSIONS' => '111000000' } }, @user, uma)
         end # Parsing permissions
         raise NoAccessError.new(0) unless @permissions[0] # Custom error if user has no USE rights

      end
   end
   def call # Calls API method given to initializer
      access = RIGHTS[method] # Checking access permissions for perform corresponding ACTION
      raise NoAccessError.new(access) unless @permissions[access] # Raising Custom error if no access granted
      send(@method) # Calling method from @method
   end
   def run
      IONe.RunAnsiblePlaybookProcess(@id)
      nil
   end
   def delete
      IONe.DeleteAnsiblePlaybookProcess(@id)
   end


   class NoAccessError < StandardError # Custom error for no access exceptions. Returns string contain which action is blocked
      def initialize action
         super()
         @action = AnsiblePlaybook::ACTIONS[action]
      end
      def message
         "Not enough rights to perform action: #{@action}!"
      end
   end
   class ParamsError < StandardError # Custom error for not valid params, returns given params inside
      def initialize params
         super()
         @params = @params
      end
      def message
         "Some arguments are missing or nil! Params:\n#{@params.inspect}"
      end
   end
end

before do # This actions will be performed before any route 
   begin
      @one_client = $cloud_auth.client(session[:user]) # Saving OpenNebula client for user
      @one_user = OpenNebula::User.new_with_id(session[:user_id], @one_client) # Saving user object
   rescue => e
      @before_exception = e.message
   end
end

get '/ansible_process' do
   begin
      pool = IONe.ListAnsiblePlaybookProcesses
      pool.delete_if {|apc| apc['uid'] != @one_user.id }
      pool.map! do | apc | # Adds user name to every object
         user =  OpenNebula::User.new_with_id( apc['uid'], @one_client)
         user.info!
         apc.merge('id' => apc['proc_id'], 'uname' => user.name)
      end
      pool.map{|playbook| playbook.duplicate_with_case! } # Duplicates every key with the same but upcase-d

      r(**{
         :ANSIBLE_PROCESS_POOL => {
            :ANSIBLE_PROCESS => pool
         }
      })
   rescue => e
      msg = e.message
      msg.crop_zmq_error! if msg.is_zmq_error? # Crops ZmqJsonRpc backtrace from exception message
      r error: e.message, backtrace: e.backtrace
   end
end

post '/ansible_process' do
   begin
      data = JSON.parse(@request_body)
      r response: { :ANSIBLE_PROCESS => {:ID => AnsiblePlaybookProcess.new(id:nil, data:data, user:@one_user).id } }
   rescue => e
      r error: e.message, params: data
   end
end

get '/ansible_process/:id' do |id|
   begin
      apc = AnsiblePlaybookProcess.new(id:id, user:@one_user) # Getting playbook
      # Saving user and group to objects
      user =  OpenNebula::User.new_with_id( apc.body['uid'], @one_client)
      user.info!
      apc.body.merge!('id' => apc.body['proc_id'], 'uname' => user.name) # Retrieving information about this objects from ONe
      apc.body.duplicate_with_case! # Duplicates every key with the same but upcase-d
      r ANSIBLE_PROCESS: apc.body
   rescue => e
      msg = e.message
      msg.crop_zmq_error! if msg.is_zmq_error? # Crops ZmqJsonRpc backtrace from exception message
      r error: e.message, backtrace: e.backtrace
   end
end

delete '/ansible_process/:id' do |id| # Deletes given playbook process
   begin
      data = {'action' => {'perform' => 'delete', 'params' => nil}}
      pb = AnsiblePlaybookProcess.new(id:id, data:data, user:@one_user)

      r response: pb.call
   rescue JSON::ParserError # If JSON.parse fails
      r error: "Broken data received, unable to parse."
   rescue => e
      msg = e.message
      msg.crop_zmq_error! if msg.is_zmq_error? # Crops ZmqJsonRpc backtrace from exception message
      r error: e.message, backtrace: e.backtrace
   end
end

post '/ansible_process/:id/action' do | id | # Performs action
   begin
      data = JSON.parse(@request_body)
      pb = AnsiblePlaybookProcess.new(id:id, data:data, user:@one_user)

      r response: pb.call
   rescue JSON::ParserError # If JSON.parse fails
      r error: "Broken data received, unable to parse."
   rescue => e
      msg = e.message
      msg.crop_zmq_error! if msg.is_zmq_error? # Crops ZmqJsonRpc backtrace from exception message
      r error: e.message, backtrace: e.backtrace
   end
end