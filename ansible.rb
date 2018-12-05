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
end

class AnsiblePlaybook

   attr_reader    :method, :id
   attr_accessor  :body

   RIGHTS = {
      'chown'        => 1,
      'chgrp'        => 1,
      'chmod'        => 1,
      'run'          => 0,
      'update'       => 2,
      'delete'       => 2,
      'vars'         => 0  }

   ACTIONS = ['USE', 'MANAGE', 'ADMIN']

   def initialize id:nil, data:{}, user:nil
      @user, @method, @params = user, data['method'], data['params']
      if id.nil? then
         begin
            check =  @params['name'].nil?                      ||
                     @params['body'].nil?                      ||
                     @params['extra_data'].nil?                ||
                     @params['extra_data']['PERMISSIONS'].nil?
         rescue
            raise ParamsError.new
         end
         raise ParamsError.new if check
         raise NoAccessError.new(2) unless user.groups.include? 0
         @user.info!
         id = IONe.CreateAnsiblePlaybook(@params.merge({:uid => @user.id, :gid => @user.gid}))
      end

      @body = IONe.GetAnsiblePlaybook(@id = id)
      @permissions = Array.new(3) {|uma| ansible_check_permissions(@body, @user, uma) }

      raise NoAccessError.new(0) unless @permissions[0]
   end
   def call
      access = RIGHTS[method]
      raise NoAccessError.new(access) unless @permissions[access]
      send(@method)
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
      IONe.UpdateAnsiblePlaybook( "id" => @body['id'], "uid" => @params )
   end
   def chgrp
      IONe.UpdateAnsiblePlaybook( "id" => @body['id'], "gid" => @params )
   end

   def vars
      IONe.GetAnsiblePlaybookVariables @id
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
      def message
         "Some arguments are missing or nil!"
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
      r(**{ 
         :ANSIBLE_POOL => {
            :ANSIBLE => pool
         }
      })
   rescue => e
      r error: e.message, backtrace: e.backtrace
   end
end

post '/ansible' do
   begin
      data = JSON.parse(@request_body)
      r response: { :id => AnsiblePlaybook.new(id:nil, data:data, user:@one_user).id }
   rescue => e
      @one_user.info!
      r error: e.message, backtrace: e.backtrace
   end
end

get '/ansible/:id' do | id |
   begin
      pb = AnsiblePlaybook.new(id:id, user:@one_user)
      r ANSIBLE: pb.body
   rescue => e
      r error: e.message, backtrace: e.backtrace
   end
end
get '/ansible/:id/vars' do | id |
   begin
      pb = AnsiblePlaybook.new(id:id, data:{'method' => 'vars'}, user:@one_user)
      r vars: pb.call
   rescue => e
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
      r error: e.message, backtrace: e.backtrace
   end
end
