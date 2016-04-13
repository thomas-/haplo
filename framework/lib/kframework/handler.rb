# Haplo Platform                                     http://haplo.org
# (c) Haplo Services Ltd 2006 - 2016    http://www.haplo-services.com
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.


class KFramework

  # All incoming requests are forced to be in the UTF-8 encoding
  REQUEST_ENCODING = Encoding::UTF_8

  # Not found response text
  NOT_FOUND_RESPONSE_HTML = %Q!<html><h1>Not found</h1><p>You requested a page which doesn't exist.</p><p><a href="/">Home page</a></p></html>!

  # Health reporter for uncaught exceptions
  REQUEST_EXCEPTION_HEALTH_EVENTS = KFramework::HealthEventReporter.new('REQUEST_EXCEPTION')

  # Request handling context
  RequestHandlingContext = Struct.new(:controller, :exchange)

  # Interface to the request object from the Java web server
  class JavaRequest
    include RequestMixin
    def initialize(servlet_request, body, is_ssl)
      @servlet_request = servlet_request
      @body = body
      @is_ssl = is_ssl
    end
    attr_reader :body
    def path
      @path ||= @servlet_request.getRequestURI()
    end
    def request_uri
      @request_uri ||= begin
        r = @servlet_request.getRequestURI()
        q = @servlet_request.getQueryString()
        (q != nil && q != '') ? "#{r}?#{q}" : r
      end
    end
    def query_string
      @query_string ||= (@servlet_request.getQueryString() || '')
    end
    def headers
      @headers ||= begin
        h = Headers.new
        # Normalise incoming headers like 'Capital-Letters'
        @servlet_request.getHeaderNames().each do |k|
          knormal = k.downcase.gsub(/(^|-)(\w)/) { "#{$1}#{$2.upcase}" }
          @servlet_request.getHeaders(k).each do |v|
            h.add(knormal, v)
          end
        end
        h.freeze
        h
      end
    end
    def ssl?
      @is_ssl
    end
    def method
      @method ||= @servlet_request.getMethod()
    end
    def remote_ip
      # Use this convoluted form because the address as an IP address string isn't available
      # from the Jetty request as it looks up the hostname instead.
      @remote_up ||= @servlet_request.getHttpChannel().getRemoteAddress().getAddress().getHostAddress()
    end
    # Minimal support for Jetty continuations
    ContinuationSupport = Java::OrgEclipseJettyContinuation::ContinuationSupport
    def continuation
      ContinuationSupport.getContinuation(@servlet_request)
    end
  end

  # Special exceptions
  class SecurityAbort < StandardError
  end
  class CSRFAttempt < SecurityAbort
  end
  class WrongHTTPMethod < StandardError
  end
  class RequestPathNotFound < StandardError
  end

  # Reportable error reporting
  @@reportable_error_reporter = nil
  def self.register_reportable_error_reporter(reporter)
    @@reportable_error_reporter = reporter
  end
  # Returns nil if no reporter or the exception isn't reportable
  def self.reportable_exception_error_text(e, format)
    return nil unless @@reportable_error_reporter
    @@reportable_error_reporter.call(e, format)
  end

  def handle_from_java(servlet_request, application, body_as_bytes, is_ssl, file_uploads)
    begin
      # Turn the byte[] body from java into a string
      body = (body_as_bytes == nil) ? '' : String.from_java_bytes(body_as_bytes)
      body.force_encoding(REQUEST_ENCODING)
      request = JavaRequest.new(servlet_request, body, is_ssl)
      exchange = Exchange.new(application.getApplicationID(), request)
      exchange.annotations[:uploads] = file_uploads if file_uploads != nil
      handle_with_decode_and_catch(exchange)
      response = exchange.response
      raise "No response generated by handler" if response == nil
      response.to_java_object
    rescue => e
      KApp.logger.log_exception(e)
      raise
    ensure
      KApp.logger.flush_buffered
    end
  end

  # Handle the request, wrapped in an error handler
  def handle_with_decode_and_catch(exchange)
    begin
      handle_with_decode(exchange)
    rescue CSRFAttempt => csrf
      KApp.logger.error(" ** CSRF attempt detected, blocking request **")
      exchange.response = make_csrf_response(exchange)
    rescue SecurityAbort => abort
      KApp.logger.error(" ** Generic SecurityAbort (class #{abort.class.name}), blocking request **")
      exchange.response = make_security_abort_response(exchange)
    rescue WrongHTTPMethod => wrong_method
      KApp.logger.error(" ** Wrong HTTP method used, blocking request **")
      exchange.response = make_wrong_method_response(wrong_method, exchange)
    rescue RequestPathNotFound => not_found
      KApp.logger.error("Incorrect URL requested #{exchange.request.path}")
      exchange.response = make_not_found_response(exchange)
    rescue => e
      # Is it a reportable error?
      reportable_error_text = KFramework.reportable_exception_error_text(e, :html)
      if reportable_error_text == nil
        # Not reportable or reportable errors disabled in production instance -- log error and set health event
        REQUEST_EXCEPTION_HEALTH_EVENTS.log_and_report_exception(e)
        exchange.response = make_error_response(e, exchange)
      else
        # Errors may be reported to the user if it's a plugin debug instance
        KApp.logger.error("Reportable error from #{exchange.request.path}")
        KApp.logger.log_exception(e)
        exchange.response = KFramework::DataResponse.new(reportable_error_text, 'text/html; charset=utf-8', 500)
        exchange.response.headers["X-Haplo-Reportable-Error"] = "yes"
      end
    end
  end

  def handle_with_decode(exchange)
    # Generate Rails compatible params
    query_string = exchange.request.query_string
    params = query_string.empty? ? Hash.new : Utils.parse_nested_query(query_string)
    # Delete stuff from the GET params which shouldn't be there
    params.delete('_ak')  # API keys must be posted
    params.delete('__')   # CSRF tokens must be posted
    # Add params from the POST body, if it doesn't look like XML or JSON
    # Sniff the content, rather than trusting content-type headers, as clients may not do this correctly.
    if exchange.request.post?
      body = exchange.request.body
      unless body.empty? || body =~ /\A\s*[\<\{\[]/
        params.merge!(Utils.parse_nested_query(body))
      end
    end
    # Add params from file upload?
    uploads = exchange.annotations[:uploads]
    if uploads != nil
      uploads.getParams().each do |k,v|
        params[k.to_s] = v.to_s
      end
    end
    params = HashWithIndifferentAccess.new(params)
    exchange.params = params
    handle(exchange)
  end

  def handle(exchange)
    begin
      KApp.in_application(exchange.application_id) do
        ms = Benchmark.ms do
          # Find the controller used to handle this request
          path_elements, controller_factory, annotations = @namespace.resolve(exchange.request.path)
          # If the URL didn't match anything, a nil controller would be returned. Let something else make this a 404.
          raise KFramework::RequestPathNotFound.new("Couldn't find a controller to handle this request.") if controller_factory == nil
          is_file_upload_instructions = ((exchange.annotations[:uploads] != nil) && (exchange.annotations[:uploads].getInstructionsRequired()))
          filtered_params = Hash[exchange.params.map{|k,v| [k, (k =~ KFRAMEWORK_LOGGING_PARAM_FILTER) ? '[FILTERED]' : v]}]
          KApp.logger.info("Request: #{Time.now.iso8601} #{is_file_upload_instructions ? 'FILE_UPLOAD_INSTRUCTIONS' : exchange.request.method} #{exchange.request.path}\n  app: #{KApp.current_application}\n  params: #{JSON.dump(filtered_params)}")
          # Merge in the annotations
          exchange.annotations.merge!(annotations)
          # Handle the request, storing a request context in a thread global
          controller = controller_factory.make_controller
          context = RequestHandlingContext.new(controller, exchange)
          begin
            Thread.current[:_frm_request_context] = context
            controller.handle(exchange, path_elements)
          rescue => handle_exception
            # Add more info to the exception - used by the health reporter for accurate emails
            handle_exception.instance_variable_set(:@__handle_info, [
                KApp.current_application,
                KApp.global(:ssl_hostname),
                context.exchange.request.method,
                context.exchange.request.path
              ])
            raise
          end
          unless exchange.has_response?
            # Not creating a response is bad. Throw a normal exception so it'll trigger the health alerting.
            raise "Controller #{controller_factory.name} didn't create a response for this request."
          end
        end
        KApp.logger.info("Store: #{KObjectStore.statistics.to_s}\n** Finished in #{ms.to_i}ms\n")
        true
      end
    ensure
      # Make absolutely sure the request context is cleared
      Thread.current[:_frm_request_context] = nil
    end
  end

  # Returns nil is there's no context
  def self.request_context
    Thread.current[:_frm_request_context]
  end

  def self.clear_request_context
    # NOTE: This method must raise an exception
    Thread.current[:_frm_request_context] = nil
  end

  def make_error_response(exception, exchange)
    # TODO: Make the default error message prettier
    message = "<html><h1>Internal error</h1><p>An internal error has occurred. If the problem persists, please contact support.</p></html>"
    KFramework::DataResponse.new(message, 'text/html; charset=utf-8', 500)
  end

  def make_csrf_response(exchange)
    # NOTE: IntegrationTest does pattern matching on the content of this message
    message = "<html><h1>Request denied for security reasons</h1><p>Your request looked like an attempt to circumvent security measures. If you see this message again, please contact support.</p><h2>Cookies need to be enabled</h2><p>Please check that you have enabled cookies for this web site. Disabled cookies are the most likely cause of this problem.</p>"
    # In plugin development mode remind the developer about the requirement for a CSRF token
    if PLUGIN_DEBUGGING_SUPPORT_LOADED
      message << %Q!<hr><div style="border:2px solid #f00;padding: 4px 16px"><h1>Developing a plugin?</h1><p>This message is most likely caused by omitting the CSRF token in a POSTed form.</p><p>Use the <tt>std:form:token()</tt> template function within your &lt;form&gt;. (or <tt>{{&gt;std:form_csrf_token}}</tt> for legacy Handlebars templates)</div>!
    end
    message << "</html>"
    KFramework::DataResponse.new(message, 'text/html; charset=utf-8', 403)
  end

  def make_security_abort_response(exchange)
    message = "<html><h1>Request denied for security reasons</h1><p>Your request looked like an attempt to circumvent security measures. If you see this message again, please contact support.</p></html>"
    KFramework::DataResponse.new(message, 'text/html; charset=utf-8', 403)
  end

  def make_wrong_method_response(exception, exchange)
    # NOTE: IntegrationTest does pattern matching on the content of this message
    message = "<html><h1>Request denied for security reasons</h1><p>Wrong HTTP method used, #{exception.message}</p></html>"
    KFramework::DataResponse.new(message, 'text/html; charset=utf-8', 403)
  end

  def make_not_found_response(exchange)
    if exchange.request.path =~ /\/.+\/favicon.ico\z/i
      # Silly browsers request favicon.ico at all sorts of locations, send it back to the root
      KFramework::RedirectResponse.new('/favicon.ico')
    else
      # 404 response
      KFramework::DataResponse.new(NOT_FOUND_RESPONSE_HTML, 'text/html; charset=utf-8', 404)
    end
  end

end
