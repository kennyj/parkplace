class Time
    def to_default_s
        strftime("%B %d, %Y at %H:%M")
    end
end

module ParkPlace
    # For controllers which pass back XML directly, this method allows quick assignment
    # of the status code and takes care of generating the XML headers.  Takes a block
    # which receives the Builder::XmlMarkup object.
    def xml status = 200
        xml = Builder::XmlMarkup.new
        xml.instruct! :xml, :version=>"1.0", :encoding=>"UTF-8"
        yield xml
        r(status, xml.target!, 'Content-Type' => 'application/xml')
    end

    # Convenient method for generating a SHA1 digest.
    def hmac_sha1(key, s)
        ipad = [].fill(0x36, 0, 64)
        opad = [].fill(0x5C, 0, 64)
        key = key.unpack("C*")
        if key.length < 64 then
        key += [].fill(0, 0, 64-key.length)
        end

        inner = []
        64.times { |i| inner.push(key[i] ^ ipad[i]) }
        inner += s.unpack("C*")

        outer = []
        64.times { |i| outer.push(key[i] ^ opad[i]) }
        outer = outer.pack("c*")
        outer += Digest::SHA1.digest(inner.pack("c*"))

        return Base64::encode64(Digest::SHA1.digest(outer)).chomp
    end

    def generate_secret
        abc = %{ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz} 
        (1..40).map { abc[rand(abc.size),1] }.join
    end

    def generate_key
        abc = %{ABCDEF0123456789} 
        (1..20).map { abc[rand(abc.size),1] }.join
    end

    POST = %{if(!this.title||confirm(this.title+'?')){var f = document.createElement('form'); this.parentNode.appendChild(f); f.method = 'POST'; f.action = this.href; f.submit();}return false;}

    # Kick out anonymous users.
    def only_authorized; raise ParkPlace::AccessDenied unless @user end
    # Kick out any users which do not have read access to a certain resource.
    def only_can_read bit; raise ParkPlace::AccessDenied unless bit.readable_by? @user end
    # Kick out any users which do not have write access to a certain resource.
    def only_can_write bit; raise ParkPlace::AccessDenied unless bit.writable_by? @user end
    # Kick out any users which do not own a certain resource.
    def only_owner_of bit; raise ParkPlace::AccessDenied unless bit.owned_by? @user end
    # Kick out any non-superusers
    def only_superusers; raise ParkPlace::AccessDenied unless @user.superuser? end

    # Build an ActiveRecord Errors set.
    def error(msg)
        @state.next_errors = ActiveRecord::Errors.new(@state).instance_eval do
            add_to_base msg
            self
        end
    end
end

module ParkPlace::S3
    # This method overrides Camping's own <tt>service</tt> method.  The idea here is
    # to set up some common instance vars and check authentication.  Here's the rundown:
    #
    # # The <tt>@meta</tt> variable is setup, containing any metadata headers
    #   (starting with <tt>x-amz-meta-</tt>.)
    # # Authorization is checked.  If a <tt>Signature</tt> is found in the URL string, it
    #   is used.  Otherwise, the <tt>Authorization</tt> HTTP header is used.
    # # If authorization is successful, the <tt>@user</tt> variable contains a valid User
    #   object.  If not, <tt>@user</tt> is nil.
    #
    # If a ParkPlace exception is thrown (anything derived from ParkPlace::ServiceError),
    # the exception is displayed as XML.
    def service(*a)
        @meta, @amz = ParkPlace::H[], ParkPlace::H[]
        @env.each do |k, v|
            k = k.downcase.gsub('_', '-')
            @amz[$1] = v.strip if k =~ /^http-x-amz-([-\w]+)$/
            @meta[$1] = v if k =~ /^http-x-amz-meta-([-\w]+)$/
        end

        auth, key_s, secret_s = *@env.HTTP_AUTHORIZATION.to_s.match(/^AWS (\w+):(.+)$/)
        date_s = @env.HTTP_X_AMZ_DATE || @env.HTTP_DATE
        if @input.Signature and Time.at(@input.Expires.to_i) >= Time.now
            key_s, secret_s, date_s = @input.AWSAccessKeyId, @input.Signature, @input.Expires
        end
        uri = @env.PATH_INFO
        uri += "?" + @env.QUERY_STRING if ParkPlace::RESOURCE_TYPES.include?(@env.QUERY_STRING)
        canonical = [@env.REQUEST_METHOD, @env.HTTP_CONTENT_MD5, @env.HTTP_CONTENT_TYPE, 
            date_s, uri]
        @amz.sort.each do |k, v|
            canonical[-1,0] = "x-amz-#{k}:#{v}"
        end
        @user = ParkPlace::Models::User.find_by_key key_s
        if @user and secret_s != hmac_sha1(@user.secret, canonical.map{|v|v.to_s.strip} * "\n")
            raise BadAuthentication
        end

        s = super(*a)
        s.headers['Server'] = 'ParkPlace'
        s
    rescue ParkPlace::ServiceError => e
        xml e.status do |x|
            x.Error do
                x.Code e.code
                x.Message e.message
                x.Resource @env.PATH_INFO
                x.RequestId Time.now.to_i
            end
        end
        self
    end

    # Parse any ACL requests which have come in.
    def requested_acl
        # FIX: parse XML
        raise NotImplemented if @input.has_key? 'acl'
        {:access => ParkPlace::CANNED_ACLS[@amz['acl']] || ParkPlace::CANNED_ACLS['private']}
    end
end
