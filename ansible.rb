require 'zmqjsonrpc'

IONe = ZmqJsonRpc::Client.new("tcp://localhost:8008")

def r **result
   JSON.pretty_generate result
end

def ansible_check_permissions pb, u, uma
   u.info!
   perm = pb['extra_data']['PERMISSIONS'].split('')
   mod = perm.values_at( *Array.new(3){ |i| uma + 3 * i }).map{| value | value == '1' ? true : false }
   return (
      (  u.id == pb['uid'] && mod[0]            ) ||
      (  u.groups.include?(pb['gid']) && mod[1] ) ||
      (                 mod[2]                  ) ||
      (          u.groups.include?(0)           )
   )
end

class String
   def is_json?
      begin
         JSON.parse self
         true
      rescue
         false
      end
   end
   def is_zmq_error?
      include? 'Server returned error (32603)'
   end
   def crop_zmq_error!
      self.slice! self.split("\n").last
      self.slice! 'Server returned error (32603): '
      self.delete! "\n"
      self
   end
end

class AnsiblePlaybook

   attr_reader    :method, :id
   attr_accessor  :body

   RIGHTS = {
      'chown'        => 2,
      'chgrp'        => 2,
      'chmod'        => 2,
      'run'          => 0,
      'update'       => 1,
      'delete'       => 2,
      'vars'         => 0,
      'clone'        => 0  }

   ACTIONS = ['USE', 'MANAGE', 'ADMIN']

   def initialize id:nil, data:{'action' => {}}, user:nil
      @user = user
      if id.nil? then
         @params = data
         begin
            check =  @params['name'].nil?                      ||
                     @params['body'].nil?                      ||
                     @params['extra_data'].nil?                ||
                     @params['extra_data']['PERMISSIONS'].nil?
         rescue
            raise ParamsError.new @params
         end
         raise ParamsError.new(@params) if check
         raise NoAccessError.new(2) unless user.groups.include? 0
         @user.info!
         @id = id = IONe.CreateAnsiblePlaybook(@params.merge({:uid => @user.id, :gid => @user.gid}))
      else
         @method, @params = data['action']['perform'], data['action']['params']
         @body = IONe.GetAnsiblePlaybook(@id = id)
         @permissions = Array.new(3) {|uma| ansible_check_permissions(@body, @user, uma) }
         
         raise NoAccessError.new(0) unless @permissions[0]
      end
   end
   def call
      access = RIGHTS[method]
      raise NoAccessError.new(access) unless @permissions[access]
      send(@method)
   end

   def clone
      
   end
   def update
      @params.each do |key, value|
         @body[key] = value
      end

      IONe.UpdateAnsiblePlaybook @body
   end
   def delete
      IONe.DeleteAnsiblePlaybook @id
   end

   def chown
      IONe.UpdateAnsiblePlaybook( "id" => @body['id'], "uid" => @params['owner_id'] ) unless @params['owner_id'] == '-1'
      chgrp unless @params['group_id'] == '-1'
   end
   def chgrp
      IONe.UpdateAnsiblePlaybook( "id" => @body['id'], "gid" => @params['group_id'] )
   end
   def chmod
      raise ParamsError.new(@params) if @params.nil?
      IONe.UpdateAnsiblePlaybook( "id" => @body['id'], "extra_data" => @body['extra_data'].merge("PERMISSIONS" => @params) )
   end

   def vars
      IONe.GetAnsiblePlaybookVariables @id
   end
   def to_process
      IONe.AnsiblePlaybookToProcess( @body['id'], @params['hosts'], 'default', @params['vars'] )
   end

   class NoAccessError < StandardError
      def initialize action
         super()
         @action = AnsiblePlaybook::ACTIONS[action]
      end
      def message
         "Not enough rights to perform action: #{@action}!"
      end
   end
   class ParamsError < StandardError
      def initialize params
         super()
         @params = @params
      end
      def message
         "Some arguments are missing or nil! Params:\n#{@params.inspect}"
      end
   end
end

before do
   begin
      @one_client = $cloud_auth.client(session[:user])
      @one_user = OpenNebula::User.new_with_id(session[:user_id], @one_client)
   rescue => e
      @before_exception = e.message
   end
end

get '/ansible' do
   begin
      pool = IONe.ListAnsiblePlaybooks
      pool.delete_if {|pb| !ansible_check_permissions(pb, @one_user, 0) }
      pool.map! do | pb |
         user, group =  OpenNebula::User.new_with_id( pb['uid'], @one_client),
                        OpenNebula::Group.new_with_id( pb['gid'], @one_client)
         user.info!; group.info!
         pb.merge('uname' => user.name, 'gname' => group.name)
      end
      r(**{ 
         :ANSIBLE_POOL => {
            :ANSIBLE => pool
         }
      })
   rescue => e
      msg = e.message
      msg.crop_zmq_error! if msg.is_zmq_error?
      r error: e.message, backtrace: e.backtrace
   end
end

post '/ansible' do
   begin
      data = JSON.parse(@request_body)
      r response: { :id => AnsiblePlaybook.new(id:nil, data:data, user:@one_user).id }
   rescue => e
      msg = e.message
      msg.crop_zmq_error! if msg.is_zmq_error?
      @one_user.info!
      r error: e.message, backtrace: e.backtrace, data:data
   end
end

delete '/ansible/:id' do |id|
   begin
      data = {'action' => {'perform' => 'delete', 'params' => nil}}
      pb = AnsiblePlaybook.new(id:id, data:data, user:@one_user)

      r response: pb.call
   rescue JSON::ParserError
      r error: "Broken data received, unable to parse."
   rescue => e
      msg = e.message
      msg.crop_zmq_error! if msg.is_zmq_error?
      r error: e.message, backtrace: e.backtrace
   end
end

get '/ansible/:id' do | id |
   begin
      pb = AnsiblePlaybook.new(id:id, user:@one_user)
      user, group =  OpenNebula::User.new_with_id( pb.body['uid'], @one_client),
                     OpenNebula::Group.new_with_id( pb.body['gid'], @one_client)
      user.info!; group.info!
      r ANSIBLE: pb.body.merge('uname' => user.name, 'gname' => group.name)
   rescue => e
      msg = e.message
      msg.crop_zmq_error! if msg.is_zmq_error?
      r error: e.message, backtrace: e.backtrace
   end
end
get '/ansible/:id/vars' do | id |
   begin
      pb = AnsiblePlaybook.new(id:id, data:{'method' => 'vars'}, user:@one_user)
      r vars: pb.call
   rescue => e
      msg = e.message
      msg.crop_zmq_error! if msg.is_zmq_error?
      r error: e.message, backtrace: e.backtrace
   end
end

post '/ansible/:id/action' do | id |
   begin
      data = JSON.parse(@request_body)
      pb = AnsiblePlaybook.new(id:id, data:data, user:@one_user)

      r response: pb.call
   rescue JSON::ParserError
      r error: "Broken data received, unable to parse."
   rescue => e
      msg = e.message
      msg.crop_zmq_error! if msg.is_zmq_error?
      r error: e.message, backtrace: e.backtrace
   end
end

post '/ansible/:action' do | action |
   data = JSON.parse(@request_body)

   begin
      if action == 'check_syntax' then
         r response: IONe.CheckAnsiblePlaybookSyntax( data['body'])
      else
         r response: "Action is not defined"
      end
   rescue JSON::ParserError
      r error: "Broken data received, unable to parse."
   rescue => e
      msg = e.message
      msg.crop_zmq_error! if msg.is_zmq_error?
      r error: e.message, backtrace: e.backtrace
   end
end