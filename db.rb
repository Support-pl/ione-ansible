require 'mysql2'

# Get this values from /etc/oned.conf
$db = {
    :username => , :password => , 
    :host => , :database => 'opennebula' }

=begin
 CREATE TABLE ansible_playbook (
   id int NOT NULL AUTO_INCREMENT UNIQUE,
   uid int,
   gid int,
   name varchar(128) NOT NULL UNIQUE,
   description varchar(2048),
   body TEXT not null,
   extra_data TEXT,
   PRIMARY KEY (id) )
=end

def db
    db_client = Mysql2::Client.new $db
    if block_given? then
        result = yield db_client
        db_client.close
        db_client.closed?
        result
    else
        db_client
    end
end

class AnsiblePlaybook
    FIELDS = %w(uid gid name description body extra_data)
    TABLE = 'ansible_playbook'

    attr_reader :id
    attr_accessor :uid, :gid, :name, :description, :body, :extra_data

    def initialize **args
        args.to_s!
        if args['id'].nil? then
            @uid, @gid, @name, @description, @body, @extra_data = args.get *FIELDS
            @uid, @gid = @uid || 0, @gid || 0
            allocate
        else
            begin
                @id = args['id']
                sync
            rescue NoMethodError
                raise "Object not exists"
            end
        end
        raise "Unhandlable, id is nil" if @id.nil?
    end
    def sync
        @id,
        @uid,
        @gid,
        @name,
        @description,
        @body,
        @extra_data = get_me(@id).get *(['id'] + FIELDS)
    end

    def delete
        db do |db|
            db.query( "DELETE FROM #{AnsiblePlaybook::TABLE} WHERE id=#{@id}" )
        end
        nil
    end
    def update
        FIELDS.each do | key |
            db do |db|
                db.query( "UPDATE #{AnsiblePlaybook::TABLE} SET #{key}='#{key == 'extra_data' ? JSON.generate(send(key)) : send(key)}' WHERE id=#{@id}" )
            end
        end
        nil
    end
    def vars
        sync
        body = YAML.load(@body).first
        begin
            body['vars']
        rescue => e
            if e.message.split(':').first == 'TypeError' then
                raise "SyntaxError: Check if here is now hyphens at the playbook beginning. Playbook parse result should be Hash"
            end
        end
    end

    def run host, vars:nil, password:nil, ssh_key:nil, ione:IONe.new($client)
        unless vars.nil? then
            body = YAML.load @body
            body[0]['vars'].merge! vars
            @body = YAML.dump body
        end
        ione.AnsibleController({
            'host' => host,
            'services' => [
                runnable
            ]
        })
    end
    def runnable vars={}
        unless vars == {} then
            body = YAML.load @body
            body[0]['vars'].merge! vars
            @body = YAML.dump body
        end
        return { @name => @body }
    end
    def to_hash
        get_me
    end

    def self.list
        result = db do |db| 
            db.query( "SELECT * FROM #{TABLE}" ).to_a
        end
        result.size.times do | i |
            result[i]['extra_data'] = JSON.parse result[i]['extra_data']
        end
        result
    end

    private

    def allocate
        db do | db |
            db.query(
                "INSERT INTO #{TABLE} (#{FIELDS.join(', ')}) VALUES ('#{@uid}', '#{@gid}', '#{@name}', '#{@description}', '#{@body.gsub("'", "\'")}', '#{JSON.generate(@extra_data)}')"
            )
            @id = db.query( "SELECT id FROM #{TABLE}" ).to_a.last['id']
        end
    end
    def get_me id = @id
        me = db do |db|
            db.query( "SELECT * FROM #{TABLE} WHERE id=#{id}" ).to_a.last
        end
        me['extra_data'] = JSON.parse me['extra_data']
        me
    end
end