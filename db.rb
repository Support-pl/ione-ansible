require 'mysql2'
require 'sequel'

# Get this values from /etc/oned.conf
$DB = Sequel.connect({
    adapter: :mysql2, user: 'root', password: 'opennebula', database: 'opennebula', host: 'localhost'  })

=begin
 CREATE TABLE ansible_playbook (
   id int NOT NULL AUTO_INCREMENT UNIQUE,
   uid int,
   gid int,
   create_time int,
   name varchar(128) NOT NULL,
   description varchar(2048),
   body TEXT not null,
   extra_data TEXT,
   PRIMARY KEY (id) )
=end

class AnsiblePlaybook
    FIELDS = %w(uid gid name description body extra_data create_time)
    TABLE = 'ansible_playbook'
    DB = $DB[:ansible_playbook]

    attr_reader :id
    attr_accessor :name, :uid, :gid, :description, :body, :extra_data, :create_time

    def initialize **args
        args.to_s!
        if args['id'].nil? then
            @uid, @gid, @name, @description, @body, @extra_data = args.get *FIELDS
            @uid, @gid, @extra_data = @uid || 0, @gid || 0, @extra_data || {}

            r, msg = self.class.check_syntax(@body)
            raise RuntimeError.new(msg) unless r

            @create_time = Time.now.to_i
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
        get_me.each do |var, value|
            instance_variable_set('@' + var, value)
        end
    end
    
    def delete
        DB.where(id: @id).delete
        nil
    end
    def update
        r, msg = self.class.check_syntax(@body)
        raise RuntimeError.new(msg) unless r
        
        args = {}
        FIELDS.each do | var |
            next if var == 'create_time'
            value = instance_variable_get(('@' + var).to_sym)
            value = var == 'extra_data' ? JSON.generate(value) : value
            args[var.to_sym] = value.nil? ? '' : value
        end
        DB.where(id: @id).update( **args )

        nil
    end
    def vars
        sync
        body = YAML.load(@body).first
            body['vars']
    rescue => e
        if e.message.split(':').first == 'TypeError' then
            raise "SyntaxError: Check if here is now hyphens at the playbook beginning. Playbook parse result should be Hash"
        end
    end

    def self.check_syntax body
        body = YAML.load(body)
        raise AnsiblePlaybookSyntaxError.new( "Playbook must be array (body should start from ' - ')" ) unless body.class == Array
        raise AnsiblePlaybookSyntaxError.new( "hosts must be equal to <%group%>" ) unless body.first['hosts'] == "<%group%>"
        raise AnsiblePlaybookSyntaxError.new( "key local_action isn't acceptable" ) if body.first.has_key? 'local_action'
        return true, ""
    rescue Psych::SyntaxError => e
        return false, e.message
    rescue AnsiblePlaybookSyntaxError => e
        return false, e.message
    rescue => e
        return false, 'Unknown error: ' + e.message
    end

    def run host, vars:nil, password:nil, ssh_key:nil, ione:IONe.new($client)
        r, msg = self.class.check_syntax(@body)
        raise RuntimeError.new(msg) unless r
        
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
        r, msg = self.class.check_syntax(@body)
        raise RuntimeError.new(msg) unless r

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
        result = DB.all
        result.map{ |pb| pb.to_s! }
        result.size.times do | i |
            result[i]['extra_data'] = JSON.parse result[i]['extra_data']
        end
        result
    end

    class AnsiblePlaybookSyntaxError < StandardError
        def initialize msg
            super
            @msg = msg
        end
        def message
            @msg
        end
    end

    private

    def allocate
        args = {}
        FIELDS.each do | var |
            value = instance_variable_get(('@' + var).to_sym)
            args[var.to_sym] = value.nil? ? '' : value
        end
        args[:extra_data] = JSON.generate(args[:extra_data])
        @id = DB.insert( **args )
    end
    def get_me id = @id
        me = DB.where(id: @id).to_a.last.to_s!
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
   log TEXT NOT NULL,
   hosts TEXT NOT NULL,
   vars TEXT NOT NULL,
   playbook_name varchar(128) NOT NULL,
   runnable TEXT NOT NULL,
   comment TEXT,
   codes VARCHAR(128) NOT NULL,
   run_after TEXT,
   PRIMARY KEY (proc_id) )
=end

class AnsiblePlaybookProcess

    attr_reader :id, :install_id, :hosts, :start_time, :end_time

    FIELDS  = %w(
        uid playbook_id install_id
        create_time start_time end_time
        status log hosts 
        vars playbook_name runnable
        comment codes run_after
    )
    
    TABLE   = 'ansible_playbook_process'
    
    STATUS = {
        '0' => 'PENDING',
        '1' => 'RUNNING',
        'ok' => 'SUCCESS',
        'changed' => 'CHANGED',
        'unreachable' => 'UNREACHABLE',
        'failed' => 'FAILED',
        '6' => 'LOST',
        'done' => 'DONE'
    }
    DB = $DB[:ansible_playbook_process]

    # hosts: { 'vmid' => [ip:port, credentials]}
    def initialize proc_id:nil, playbook_id:nil, uid:nil, hosts:{}, vars:{}, comment:'', auth:'default', run_after:{}
        if proc_id.nil? then
            @uid, @playbook_id = uid, playbook_id
            @install_id = SecureRandom.uuid + '-' + Date.today.strftime
            @create_time, @start_time, @end_time = Time.now.to_i, -1, -1
            @status = '0'
            @log = ''
            @comment = comment.to_s
            @hosts = hosts
            @vars = vars
            @playbook = AnsiblePlaybook.new(id: @playbook_id)
            @playbook_name, @runnable = @playbook.runnable(@vars).to_a[0]
            @codes = '—'
            @run_after = run_after
        else
            @id = proc_id
            sync
        end
    rescue
        @playbook = @playbook_name = @runnable = ''
        @status = 'done'
    ensure
        allocate if @id.nil?
    end
    
    def run thread = true
        nil if STATUS.keys.index(@status) > 0
        @start_time, @status = Time.now.to_i, '1'
        
        update

        process = Proc.new do
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
                        @hosts.values.each {|host| file.write("#{host[0]}\n") }
                    end
                    # Upload Hosts file
                    ssh.sftp.upload!("/tmp/#{@install_id}.ini", "/tmp/#{@install_id}.ini")
                    # Creating run log
                    ssh.exec!("echo 'START' > /tmp/#{@install_id}.runlog")
                    # Run Playbook
                    ssh.exec!(
                        "ansible-playbook /tmp/#{@install_id}.yml -i /tmp/#{@install_id}.ini >> /tmp/#{@install_id}.runlog; echo 'DONE' >> /tmp/#{@install_id}.runlog" )
                
                    @end_time = Time.now.to_i
                end
                clean
                scan
            rescue
                @status = 'failed'
            ensure
                update
            end
        end
        if thread then
            Thread.new do
                process.call
            end
        else
            process.call
        end
    ensure
        update
    end

    def scan
        return nil if STATUS.keys.index(@status) > 1
        Net::SSH.start( ANSIBLE_HOST, ANSIBLE_HOST_USER, :port => ANSIBLE_HOST_PORT ) do | ssh |
            ssh.sftp.download!("/tmp/#{@install_id}.runlog", "/tmp/#{@install_id}.runlog")
            @log = File.read("/tmp/#{@install_id}.runlog")
            if @log.split(/\n/)[-1] == 'DONE' then
                ssh.sftp.remove("/tmp/#{@install_id}.runlog")
                @log.slice!("START\n")
                @log.slice!("\nDONE\n")
            else
                @log = ""
                return
            end
        end if @log == ""

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

        run_after
    rescue => e
        puts e.message, e.backtrace
        @status = '6'
    ensure
        update
    end
    def delete
        @status = 'done'
    ensure
        update
    end
    def status
        STATUS[@status]
    end
    def to_hash
        get_me
    end
    def human
        r = to_hash
        r['status'] = STATUS[r['status']]
        r
    end
    def run_after
        return if @run_after['method'].nil?

        if @run_after['params'].nil? then
            IONe.new($client, $db).send(@run_after['method'])         
        elsif @run_after['params'].class == Array then
            IONe.new($client, $db).send(@run_after['method'], *@run_after['params'])
        else
            IONe.new($client, $db).send(@run_after['method'], @run_after['params'])
        end
    end

    def self.list
        result = DB.all
        result.map{ |pb| pb.to_s! }
        result.each do |app|
            app['status'] = STATUS[app['status']]
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
        args = {}
        FIELDS.each do | var |
            next if var == 'create_time'
            value = instance_variable_get(('@' + var).to_sym)
            value = (['vars', 'hosts', 'codes', 'run_after'].include?(var) && value != '—' ) ? JSON.generate(value) : value
            args[var.to_sym] = value.nil? ? '' : value
        end
        DB.where(proc_id: @id).update( **args )
        nil
    end
    def allocate
        args = {}
        FIELDS.each do | var |
            value = instance_variable_get(('@' + var).to_sym)
            args[var.to_sym] = value.nil? ? '' : value
        end
        args[:vars] = JSON.generate(args[:vars])
        args[:hosts] = JSON.generate(args[:hosts])
        args[:codes] = args[:codes] == '—' ? args[:codes] : JSON.generate(args[:codes])
        args[:run_after] = JSON.generate(args[:run_after])
        @id = DB.insert( **args )
    end
    def sync
        get_me.each do |var, value|
            instance_variable_set('@' + var, value)
        end
    end
    def get_me id = @id
        me = DB.where(proc_id: @id).to_a.last.to_s!
        me['vars'] = JSON.parse me['vars']
        me['hosts'] = JSON.parse me['hosts']
        me['codes'] = me['codes'] == '—' ? me['codes'] : JSON.parse( me['codes'])
        me['run_after'] = JSON.parse me['run_after']
        me
    end
end