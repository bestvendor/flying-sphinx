class FlyingSphinx::IndexRequest
  attr_reader :index_id, :indices

  INDEX_COMPLETE_CHECKING_INTERVAL = 3

  # Remove all Delta jobs from the queue. If the
  # delayed_jobs table does not exist, this method will do nothing.
  #
  def self.cancel_jobs
    return unless defined?(::Delayed) && ::Delayed::Job.table_exists?

    ::Delayed::Job.delete_all "handler LIKE '--- !ruby/object:FlyingSphinx::%'"
  end

  def self.output_last_index
    index = FlyingSphinx::Configuration.new.api.get('indices/last').body
    puts "Index Job Status: #{index.status}"
    puts "Index Log:\n#{index.log}"
  end

  def initialize(indices = [])
    @indices = indices
  end

  # Shows index name in Delayed::Job#name.
  #
  def display_name
    "#{self.class.name} for #{indices.join(', ')}"
  end

  def update_and_index
    update_sphinx_configuration
    update_sphinx_reference_files
    index
  end

  def status_message
    raise "Index Request failed to start. Something's not right!" if @index_id.nil?

    status = request_status
    case status
    when 'FINISHED'
      'Index Request has completed.'
    when 'FAILED'
      'Index Request failed.'
    when 'PENDING'
      'Index Request is still pending - something has gone wrong.'
    else
      "Unknown index response: '#{status}'."
    end
  end

  # Runs Sphinx's indexer tool to process the index. Currently assumes Sphinx is
  # running.
  #
  # @return [Boolean] true
  #
  def perform
    index
    true
  end

  private

  def configuration
    @configuration ||= FlyingSphinx::Configuration.new
  end

  def update_sphinx_configuration
    api.put '/',
      :configuration  => configuration.sphinx_configuration,
      :sphinx_version => ThinkingSphinx::Configuration.instance.version
  end

  def update_sphinx_reference_files
    FlyingSphinx::Configuration::FileSettings.each do |setting|
      configuration.file_setting_pairs(setting).each do |local, remote|
        api.post '/add_file',
          :setting   => setting.to_s,
          :file_name => remote.split('/').last,
          :content   => open(local).read
      end
    end
  end

  def index
    if FlyingSphinx::Tunnel.required?
      tunnelled_index
    else
      direct_index
    end
  rescue Net::SSH::Exception => err
    # Server closed the connection on us. That's (hopefully) expected, nothing
    # to worry about.
    puts "SSH/Indexing Error: #{err.message}" if log?
  rescue RuntimeError => err
    puts err.message
  end

  def tunnelled_index
    FlyingSphinx::Tunnel.connect(configuration) do
      begin_request unless request_begun?

      true
    end
  end

  def direct_index
    begin_request
    while !request_complete?
      sleep 3
    end
  end

  def begin_request
    response = api.post 'indices', :indices => indices.join(',')

    @index_id = response.body.id
    @request_begun = true

    raise RuntimeError, 'Your account does not support delta indexing. Upgrading plans is probably the best way around this.' if response.body.status == 'BLOCKED'
  end

  def request_begun?
    @request_begun
  end

  def request_complete?
    case request_status
    when 'FINISHED', 'FAILED'
      true
    when 'PENDING'
      false
    else
      raise "Unknown index response: '#{response.body}'"
    end
  end

  def request_status
    api.get("indices/#{index_id}").body.status
  end

  def cancel_request
    return if index_id.nil?

    puts "Connecting Flying Sphinx to the Database failed"
    puts "Cancelling Index Request..."

    api.put("indices/#{index_id}", :status => 'CANCELLED')
  end

  def api
    configuration.api
  end

  def log?
    ENV['VERBOSE_LOGGING'] && ENV['VERBOSE_LOGGING'].length > 0
  end
end
