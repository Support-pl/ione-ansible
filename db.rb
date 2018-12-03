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
        db.query(
            "DELETE FROM #{AnsiblePlaybook::TABLE} WHERE id=#{@id}"
        )
        nil
    end
    def update
        AnsiblePlaybook::FIELDS.each do | key |
            db.query(
                "UPDATE #{AnsiblePlaybook::TABLE} SET #{key}='#{send(key)}' WHERE id=#{@id}"
            )
        end
        nil
    end
    def vars
        sync
        body = YAML.load @body
        begin
            body['vars']
        rescue => e
            if e.message.split(':').first = 'TypeError' then
                raise "SyntaxError: Check if here is now hyphens at the playbook beginning. Playbook parse result should be Hash"
            end
        end
    end

    def run host, vars:nil, password:nil, ssh_key:nil
        unless vars.nil? then
            body = YAML.load @body
            body['vars'].merge! vars
            @body = YAML.dump body
        end
        IONe.new($client).AnsibleController({
            'host' => host,
            'services' => [
                runnable
            ]
        })
    end
    def runnable
        return { name => body }
    end
    def to_hash
        get_me
    end

    def self.list
        db.query(
            "SELECT * FROM #{AnsiblePlaybook::TABLE}"
        ).to_a
    end

    private

    def allocate
        db do | db |
            db.query(
                "INSERT INTO #{AnsiblePlaybook::TABLE} (#{AnsiblePlaybook::FIELDS.join(', ')}) VALUES ('#{@uid}', '#{@gid}', '#{@name}', '#{@description}', '#{@body}', '#{@extra}')"
            )
            @id = db.query( "SELECT id FROM #{AnsiblePlaybook::TABLE}" ).to_a.last['id']
        end
    end
    def get_me id = @id
        db.query(
            "SELECT * FROM #{AnsiblePlaybook::TABLE} WHERE id=#{id}"
        ).to_a.last
    end
end