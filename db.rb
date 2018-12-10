require 'mysql2'

# Get this values from /etc/oned.conf
$db = {
    :username => 'root', :password => 'opennebula', 
    :host => 'localhost', :database => 'opennebula' }

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

=begin
 CREATE TABLE ansible_playbook_process (
   proc_id INT NOT NULL AUTO_INCREMENT UNIQUE,
   uid INT NOT NULL,
   playbook_id INT NOT NULL,
   install_id VARCHAR(128) NOT NULL UNIQUE,
   create_time INT NOT NULL,
   start_time INT,
   end_time INT,
   status VARCHAR(12),
   log TEXT,
   hosts TEXT NOT NULL,
   vars TEXT NOT NULL,
   PRIMARY KEY (proc_id) )
=end

class AnsiblePlaybookProcess

    attr_reader :id, :install_id

    FIELDS  = %w(uid playbook_id install_id create_time start_time end_time status log hosts vars)
    TABLE   = 'ansible_playbook_process'
    
    STATUS = {
        '0' => 'PENDING',
        '1' => 'RUNNING',
        'ok' => 'SUCCESS',
        'changed' => 'CHANGED',
        'unreachable' => 'UNREACHABLE',
        'failed' => 'FAILED',
        '6' => 'LOST'
    }

    def initialize proc_id:nil, playbook_id:nil, uid:nil, hosts:[], vars:{}, auth:'default'
        if proc_id.nil? then
            @uid, @playbook_id = uid, playbook_id
            @install_id = SecureRandom.uuid + '-' + Date.today.strftime
            @create_time, @start_time, @end_time = Time.now.to_i, -1, -1
            @status = '0'
            @log = nil
            @hosts = hosts
            @vars = vars
        else
            @id = proc_id
            sync
        end
        @playbook = AnsiblePlaybook.new(id: @playbook_id)
        @service, @runnable = @playbook.runnable(@vars).to_a[0]
    ensure
        allocate if @id.nil?
    end
    
    def run
        nil if AnsiblePlaybookProcess::STATUS.keys.index(@status) > 0
        @start_time, @status = Time.now.to_i, '1'
        Thread.new do
            begin
                Net::SSH.start( ANSIBLE_HOST, ANSIBLE_HOST_USER, :port => ANSIBLE_HOST_PORT ) do | ssh |
                    # Create local Playbook version
                    File.open("/tmp/#{@install_id}.yml", 'w') do |file|
                        file.write(
                            @runnable.gsub('<%group%>', @install_id) )
                    end
                    # Upload Playbook to Ansible host
                    ssh.sftp.upload!("/tmp/#{@install_id}.yml", "/tmp/#{@install_id}.yml")
                    # Create local Hosts File
                    File.open("/tmp/#{@install_id}.ini", 'w') do |file|
                        file.write("[#{@install_id}]\n")
                        @hosts.each {|host| file.write("#{host}\n") }
                    end
                    # Upload Hosts file
                    ssh.sftp.upload!("/tmp/#{@install_id}.ini", "/tmp/#{@install_id}.ini")
                    # Creating run log
                    ssh.exec!("echo 'START' > /tmp/#{@install_id}.runlog")
                    # Run Playbook
                    ssh.exec!(
                        "ansible-playbook /tmp/#{@install_id}.yml -i /tmp/#{@install_id}.ini >> /tmp/#{@install_id}.runlog; echo 'DONE' >> /tmp/#{@install_id}.runlog" )
                
                    @end_time = Time.now.to_i
                    clean
                    scan
                end
            rescue
                @status = 'failed'
            ensure
                update
            end
        end
    ensure
        update
    end

    def scan
        return nil if AnsiblePlaybookProcess::STATUS.keys.index(@status) > 1
        Net::SSH.start( ANSIBLE_HOST, ANSIBLE_HOST_USER, :port => ANSIBLE_HOST_PORT ) do | ssh |
            ssh.sftp.download!("/tmp/#{@install_id}.runlog", "/tmp/#{@install_id}.runlog")
            @log = File.read("/tmp/#{@install_id}.runlog")
            if @log.split(/\n/)[-1] == 'DONE' then
                ssh.sftp.remove("/tmp/#{@install_id}.runlog")
                @log.slice!("START\n")
                @log.slice!("\nDONE\n")
            else
                @log = nil
                return
            end
        end if @log == nil

        codes = {}
        
        @log.split('PLAY RECAP').last.split(/\n/).map do | host |
            host = host.split("\n").last.split(" ")
            next if host.size == 1
            codes.store host[0], {}
            host[-4..-1].map do |code|
                code = code.split("=")
                codes[host[0]].store(code.first, code.last.to_i)
            end
        end
        
        if codes.values.inject(0){|sum, codes| sum +=  codes['failed']} != 0 then
            @status = 'failed'
        elsif codes.values.inject(0){|sum, codes| sum +=  codes['unreachable']} != 0 then
            @status = 'unreachable'
        else
            @status = codes.values.last.keys.map do | key |
                { key => codes.values.inject(0){|sum, codes| sum +=  codes[key]} }
            end.sort_by{|attribute| attribute.values.last }.last.keys.last
        end
        
        @codes = codes
    rescue => e
        puts e.message, e.backtrace
        @status = '6'
    ensure
        update
    end
    def status
        STATUS[@status]
    end
    def to_hash
        db do |db|
            db.query( "SELECT * FROM #{TABLE} WHERE proc_id=#{@id}" ).to_a.last
        end
    end

    def self.list
        result = db do |db| 
            db.query( "SELECT * FROM #{TABLE}" ).to_a
        end
        result
    end
    
    private

    def clean
        Net::SSH.start( ANSIBLE_HOST, ANSIBLE_HOST_USER, :port => ANSIBLE_HOST_PORT ) do | ssh |
            ssh.sftp.remove!("/tmp/#{@install_id}.ini")
            File.delete("/tmp/#{@install_id}.ini")
            ssh.sftp.remove!("/tmp/#{@install_id}.yml")
            File.delete("/tmp/#{@install_id}.yml")
            ssh.sftp.remove("/tmp/#{@install_id}.retry")
        end
        nil
    end
    def update
        db do |db|
            FIELDS.each do | key |
                db.query( "UPDATE #{TABLE} SET #{key}=#{
                    var = instance_variable_get ('@' + key).to_sym
                    var = JSON.generate var if var.class == Array || var.class == Hash
                    var = "'#{var}'" if var.class == String
                    var = 'null' if var.nil?
                    var
                } WHERE proc_id=#{@id}" )
            end
        end
        nil
    end
    def allocate
        db do | db |
            db.query(
                "INSERT INTO #{TABLE} (#{FIELDS.join(', ')}) VALUES (#{
                    FIELDS.map do |var|
                        var = instance_variable_get(('@' + var).to_sym)
                        var = JSON.generate var if var.class == Array || var.class == Hash
                        var = "'#{var}'" if var.class == String
                        var = 'null' if var.nil?
                        var
                    end.join(', ')})"
            )
            @id = db.query( "SELECT proc_id FROM #{TABLE}" ).to_a.last['proc_id']
        end
    end
    def sync
        db do |db|
            db.query( "SELECT * FROM #{TABLE} WHERE proc_id=#{@id}" ).to_a.last.each {|key, value| instance_variable_set(('@' + key).to_sym, value)}
        end
        @hosts = JSON.parse @hosts
        @vars = JSON.parse @vars
    end
end

app = AnsiblePlaybookProcess.new playbook_id:23, uid:0, hosts:['185.66.68.11:52222', '185.66.68.114:22', '185.66.69.206:52222'], vars:{'cause_error' => 'false', 'work_time' => 5}, auth:'default'