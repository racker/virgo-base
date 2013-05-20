import os
import sys
import array
import re

from argparse import ArgumentParser

tmpl_header = '''
/* autogenerated by bin2c.py */
'''
tmpl_entry_header = "static const unsigned char %s[] = {\n"
tmpl_entry_footer = "}\n"
tmpl_footer = ''' '''

def output(stream, data):
    stream.write(data)

def perform_conversion(input_filename, output_filename):
    filename, ext = os.path.splitext(os.path.basename(args.input))
    filename = re.sub(r"[-/]", '_', filename)

    if output_filename == '-':
        stream = sys.stdout
    else:
        pass

    bytes = array.array('B', open(input_filename, "rb").read())

    output(stream, tmpl_header)
    output(stream, tmpl_entry_header % filename)

    i = 0
    count = len(bytes)
    for byte in bytes:
        if i % 8 == 0:
            output(stream, '  ')

        output(stream, "0x%02x" % byte)

        if (i + 1) < count:
            output(stream, ', ')

        if (i % 8) == 7:
            output(stream, '\n')

        i += 1

    output(stream, tmpl_entry_footer)
    output(stream, tmpl_footer)

if __name__ == '__main__':
    parser = ArgumentParser()
    parser.add_argument('-i', '--input', required=True, help='input file')
    parser.add_argument('-o', '--output', required=True, help='output file')
    args = parser.parse_args()

    perform_conversion(args.input, args.output)