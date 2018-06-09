########################################################
#               Ansible Playbooks runner               #
########################################################

puts 'Initializing Ansible constants'
ANSIBLE_HOST = CONF['AnsibleServer']['host']
ANSIBLE_HOST_PORT = CONF['AnsibleServer']['port']
ANSIBLE_HOST_USER = CONF['AnsibleServer']['user']
require 'net/ssh'
require 'net/sftp'

puts 'Extending handler class by AnsibleController'

class IONe
    def AnsibleController(params)
        LOG params.merge!({:method => __method__.to_s}).debug_out, 'DEBUG'
        host, playbooks = params['host'], params['services']
        return if DEBUG
        ip, err = host.split(':').first, ""
        Thread.new do
            playbooks.each do |service, playbook|
                installid = id_gen().crypt(service[0..3]).delete('!@#$%^&*()_+:"\'.,\/\\')
                LOG "#{service} should be installed on #{ip}, installation ID is: #{installid}", "AnsibleController"
                begin
                    LOG 'Connecting to Ansible', 'AnsibleController'            
                    err = "Line #{__LINE__ + 1}: Error while connecting to Ansible-server"
                    Net::SSH.start(ANSIBLE_HOST, ANSIBLE_HOST_USER, :port => ANSIBLE_HOST_PORT) do | ssh |
                        err = "Line #{__LINE__ + 1}: Error while creating temporary playbook file occurred"
                        File.open("/tmp/#{installid}.yml", 'w') { |file| file.write(playbook.gsub('{{group}}', installid)) }
                        err = "Line #{__LINE__ + 1}: Error while uploading playbook occurred"
                        ssh.sftp.upload!("/tmp/#{installid}.yml", "/tmp/#{installid}.yml")
                        err = "Line #{__LINE__ + 1}: Error while creating temporary ansible-inventory file occurred"
                        File.open("/tmp/#{installid}.ini", 'w') { |file| file.write("[#{installid}]\n#{host}\n") }
                        err = "Line #{__LINE__ + 1}: Error while uploading ansible-inventory occurred"
                        ssh.sftp.upload!("/tmp/#{installid}.ini", "/tmp/#{installid}.ini")
                        LOG 'PB and hosts have been generated', 'AnsibleController' 
                        err = "Line #{__LINE__ + 1}: Error while executing playbook occured"
                        LOG 'Executing PB', 'AnsibleController' 
                        $pbexec = ssh.exec!("ansible-playbook /tmp/#{installid}.yml -i /tmp/#{installid}.ini").split(/\n/)
                        LOG 'PB has been Executed', 'AnsibleController' 
                        def status(regexp)
                            return $pbexec.last[regexp].split(/=/).last.to_i
                        end
                        LOG 'Creating log-ticket', 'AnsibleController' 
                        LOG "#{service} installed on #{ip}", "AnsibleController"
                        LOG 'Wiping hosts and pb files', 'AnsibleController' 
                        ssh.sftp.remove!("/tmp/#{installid}.ini")
                        File.delete("/tmp/#{installid}.ini")
                        ssh.sftp.remove!("/tmp/#{installid}.yml")
                        File.delete("/tmp/#{installid}.yml")
                    end
                rescue => e
                    LOG "An Error occured, while installing #{service} on #{ip}: #{err}, Code: #{e.message}", "AnsibleController"
                end
            end
            LOG 'Ansible job ended', 'AnsibleController'
            Thread.exit
        end
        return 200
    end
end