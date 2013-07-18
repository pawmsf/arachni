=begin
    Copyright 2010-2013 Tasos Laskos <tasos.laskos@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
=end

module Arachni

require Options.dir['lib'] + 'element_filter'
require Options.dir['lib'] + 'module/output'

#
# Trainer class
#
# Analyzes key HTTP responses looking for new auditable elements.
#
# @author Tasos Laskos <tasos.laskos@gmail.com>
#
class Trainer
    include Module::Output
    include ElementFilter
    include Utilities

    MAX_TRAININGS_PER_URL = 25

    # @param    [Arachni::Framework]  framework
    def initialize( framework )
        @framework  = framework
        @updated    = false

        @on_new_page_blocks = []
        @trainings_per_url  = Hash.new( 0 )

        # get us setup using the page that is being audited as a seed page
        framework.on_audit_page { |page| self.page = page }

        framework.http.add_on_queue do |req, _|
            next if !req.train?

            req.on_complete do |res|
                # handle redirections
                if res.redirection?
                    reference_url = @page ? @page.url : framework.opts.url
                    framework.http.get( to_absolute( res.headers.location, reference_url ) ) do |res2|
                        push( res2 )
                    end
                else
                    push( res )
                end
            end
        end
    end

    #
    # Passes the response on for analysis.
    #
    # If the response contains new elements it creates a new page
    # with those elements and pushes it a buffer.
    #
    # These new pages can then be retrieved by flushing the buffer (#flush).
    #
    # @param  [Arachni::HTTP::Response]  response
    #
    def push( response )
        if !@page
            print_debug 'No seed page assigned yet.'
            return
        end

        if @framework.link_count_limit_reached?
            print_info 'Link count limit reached, skipping analysis.'
            return
        end

        @parser = Parser.new( response )

        return false if !@parser.text? ||
            @trainings_per_url[@parser.url] >= MAX_TRAININGS_PER_URL ||
            redundant_path?( @parser.url ) || skip_resource?( response )

        analyze response
        true
    rescue => e
        print_error e.to_s
        print_error_backtrace e
    end

    #
    # Sets the current working page and inits the element DB.
    #
    # @param    [Arachni::Page]    page
    #
    def page=( page )
        init_db_from_page page
        @page = page.dup
    end
    alias :init :page=

    def on_new_page( &block )
        @on_new_page_blocks << block
    end

    private

    #
    # Analyzes a response looking for new links, forms and cookies.
    #
    # @param   [Arachni::HTTP::Response]  res
    #
    def analyze( res )
        print_debug "Started for response with request ID: ##{res.request.id}"

        new_elements = {
            cookies: find_new( :cookies )
        }

        # if the response body is the same as the page body and
        # no new cookies have appeared there's no reason to analyze the page
        if res.body == @page.body && !@updated && @page.url == @parser.url
            print_debug 'Page hasn\'t changed.'
            return
        end

        [ :forms, :links ].each { |type| new_elements[type] = find_new( type ) }

        if @updated
            @trainings_per_url[@parser.url] += 1

            page = @parser.page

            # Only keep new elements.
            new_elements.each { |type, elements| page.send( "#{type}=", elements ) }

            @on_new_page_blocks.each { |block| block.call page }

            # feed the page back to the framework
            @framework.push_to_page_queue( page )

            @updated = false
        end

        print_debug 'Training complete.'
    end

    def find_new( element_type )
        elements, count = send( "update_#{element_type}".to_sym, @parser.send( element_type ) )
        return [] if count == 0

        @updated = true
        print_info "Found #{count} new #{element_type}."

        prepare_new_elements( elements )
    end

    def prepare_new_elements( elements )
        elements.flatten.map { |elem| elem.override_instance_scope; elem }
    end

    def self.info
        { name: 'Trainer' }
    end

end
end
